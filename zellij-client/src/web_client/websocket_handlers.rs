use crate::web_client::authentication::SessionTokenHash;
use crate::web_client::control_message::{
    SetConfigPayload, TerminalMetricsPayload, WebClientToWebServerControlMessage,
    WebClientToWebServerControlMessagePayload, WebServerToWebClientControlMessage,
};
use crate::web_client::message_handlers::{
    parse_stdin, render_to_client, send_control_messages_to_client, StdinSession,
};
use crate::web_client::server_listener::zellij_server_listener;
use crate::web_client::types::{AppState, TerminalParams};

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path as AxumPath, Query, State,
    },
    response::IntoResponse,
};
use futures::StreamExt;
use std::sync::{atomic::AtomicBool, Arc};
use tokio_util::sync::CancellationToken;
use zellij_utils::{
    input::{actions::Action, mouse::MouseEvent},
    ipc::{ClientToServerMsg, PixelDimensions},
    pane_size::SizeInPixels,
};

pub async fn ws_handler_control(
    ws: WebSocketUpgrade,
    _path: Option<AxumPath<String>>,
    State(state): State<AppState>,
    axum::Extension(session_token_hash): axum::Extension<SessionTokenHash>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws_control(socket, state, session_token_hash))
}

pub async fn ws_handler_terminal(
    ws: WebSocketUpgrade,
    session_name: Option<AxumPath<String>>,
    Query(params): Query<TerminalParams>,
    State(state): State<AppState>,
    axum::Extension(session_token_hash): axum::Extension<SessionTokenHash>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| {
        handle_ws_terminal(socket, session_name, params, state, session_token_hash)
    })
}

async fn handle_ws_control(
    socket: WebSocket,
    state: AppState,
    session_token_hash: SessionTokenHash,
) {
    let payload = SetConfigPayload::from(&*state.config.lock().unwrap());
    let set_config_msg = WebServerToWebClientControlMessage::SetConfig(payload);

    let (control_socket_tx, mut control_socket_rx) = socket.split();

    let (control_channel_tx, control_channel_rx) = tokio::sync::mpsc::unbounded_channel();
    send_control_messages_to_client(control_channel_rx, control_socket_tx);

    let _ = control_channel_tx.send(Message::Text(
        serde_json::to_string(&set_config_msg).unwrap().into(),
    ));

    let send_message_to_server = |deserialized_msg: WebClientToWebServerControlMessage| {
        let Some(client_connection) = state
            .connection_table
            .lock()
            .unwrap()
            .get_client_os_api(&deserialized_msg.web_client_id)
            .cloned()
        else {
            log::error!("Unknown web_client_id: {}", deserialized_msg.web_client_id);
            return;
        };
        let client_msg = match deserialized_msg.payload {
            WebClientToWebServerControlMessagePayload::TerminalResize(size) => {
                vec![ClientToServerMsg::TerminalResize { new_size: size }]
            },
            WebClientToWebServerControlMessagePayload::TerminalMetrics(metrics) => {
                vec![terminal_metrics_to_ipc(metrics)]
            },
            WebClientToWebServerControlMessagePayload::ViewportScroll(scroll) => {
                let lines = scroll.lines.clamp(1, 30);
                let action = match scroll.direction {
                    crate::web_client::control_message::ViewportScrollDirection::Up => {
                        Action::ScrollUp
                    },
                    crate::web_client::control_message::ViewportScrollDirection::Down => {
                        Action::ScrollDown
                    },
                };
                (0..lines)
                    .map(|_| ClientToServerMsg::Action {
                        action: action.clone(),
                        terminal_id: None,
                        client_id: None,
                        is_cli_client: false,
                    })
                    .collect()
            },
        };

        for client_msg in client_msg {
            let _ = client_connection.send_to_server(client_msg);
        }
    };

    let mut set_client_control_channel = false;
    let mut registered_web_client_id = None;

    while let Some(Ok(msg)) = control_socket_rx.next().await {
        match msg {
            Message::Text(msg) => {
                let deserialized_msg: Result<WebClientToWebServerControlMessage, _> =
                    serde_json::from_str(&msg);
                match deserialized_msg {
                    Ok(deserialized_msg) => {
                        if !state
                            .connection_table
                            .lock()
                            .unwrap()
                            .verify_client_ownership(
                                &deserialized_msg.web_client_id,
                                &session_token_hash.0,
                            )
                        {
                            log::error!(
                                "Client attempted to use web_client_id {} that does not belong to their session",
                                deserialized_msg.web_client_id
                            );
                            break;
                        }
                        if !set_client_control_channel {
                            set_client_control_channel = true;
                            registered_web_client_id = Some(deserialized_msg.web_client_id.clone());
                            state
                                .connection_table
                                .lock()
                                .unwrap()
                                .add_client_control_tx(
                                    &deserialized_msg.web_client_id,
                                    control_channel_tx.clone(),
                                );
                        }
                        send_message_to_server(deserialized_msg);
                    },
                    Err(e) => {
                        log::error!("Failed to deserialize client msg: {:?}", e);
                    },
                }
            },
            Message::Close(_) => {
                break;
            },
            _ => {
                log::error!("Unsupported messagetype : {:?}", msg);
            },
        }
    }
    if let Some(web_client_id) = registered_web_client_id {
        state
            .connection_table
            .lock()
            .unwrap()
            .clear_client_control_tx_if_same(&web_client_id, &control_channel_tx);
    }
}

async fn handle_ws_terminal(
    socket: WebSocket,
    session_name: Option<AxumPath<String>>,
    params: TerminalParams,
    state: AppState,
    session_token_hash: SessionTokenHash,
) {
    let web_client_id = params.web_client_id;

    // Verify the session token owns this web_client_id
    if !state
        .connection_table
        .lock()
        .unwrap()
        .verify_client_ownership(&web_client_id, &session_token_hash.0)
    {
        log::error!(
            "Terminal WebSocket: client does not own web_client_id {}",
            web_client_id
        );
        return;
    }

    let Some(os_input) = state
        .connection_table
        .lock()
        .unwrap()
        .get_client_os_api(&web_client_id)
        .cloned()
    else {
        log::error!("Unknown web_client_id: {}", web_client_id);
        return;
    };

    let (client_terminal_channel_tx, mut client_terminal_channel_rx) = socket.split();
    let (stdout_channel_tx, stdout_channel_rx) = tokio::sync::mpsc::unbounded_channel();
    state
        .connection_table
        .lock()
        .unwrap()
        .add_client_terminal_tx(&web_client_id, stdout_channel_tx);

    let (attachment_complete_tx, attachment_complete_rx) = tokio::sync::oneshot::channel();

    // A connection with no session name in the path (the web root,
    // `/ws/terminal`) is the "create a new session" entrypoint, so allow
    // creation there even when the client did not pass `create=true`. A
    // named path (`/ws/terminal/{session}`) still defaults to attach-only
    // so a stale/typo'd name does not silently spawn a duplicate server.
    let allow_create = params.create.unwrap_or(session_name.is_none());

    zellij_server_listener(
        os_input.clone(),
        state.connection_table.clone(),
        session_name.map(|p| p.0),
        state.config.lock().unwrap().clone(),
        state.config_options.clone(),
        Some(state.config_file_path.clone()),
        web_client_id.clone(),
        state.session_manager.clone(),
        Some(attachment_complete_tx),
        allow_create,
        params.tab_position_to_focus,
    );

    let terminal_channel_cancellation_token = CancellationToken::new();
    let should_not_reconnect = state
        .connection_table
        .lock()
        .unwrap()
        .get_should_not_reconnect_flag(&web_client_id)
        .unwrap_or_else(|| Arc::new(AtomicBool::new(false)));
    render_to_client(
        stdout_channel_rx,
        client_terminal_channel_tx,
        terminal_channel_cancellation_token.clone(),
        should_not_reconnect,
    );
    state
        .connection_table
        .lock()
        .unwrap()
        .add_client_terminal_channel_cancellation_token(
            &web_client_id,
            terminal_channel_cancellation_token,
        );

    let explicitly_disable_kitty_keyboard_protocol = state
        .config
        .lock()
        .unwrap()
        .options
        .support_kitty_keyboard_protocol
        .map(|e| !e)
        .unwrap_or(false);

    let _ = attachment_complete_rx.await;

    let mut mouse_old_event = MouseEvent::new();
    // Per-connection parser state. Hoisted so a CSI / Kitty sequence
    // split across two WebSocket frames resolves on the second frame.
    let mut stdin_session = StdinSession::new(explicitly_disable_kitty_keyboard_protocol);
    let finalize_idle = std::time::Duration::from_millis(50);
    loop {
        // When termwiz is holding ambiguous-but-complete events from
        // the previous frame, race the next frame against an idle
        // timeout so the held events still drain if no further frame
        // arrives.
        let result = if stdin_session.pending_finalize() {
            tokio::select! {
                msg = client_terminal_channel_rx.next() => Some(msg),
                _ = tokio::time::sleep(finalize_idle) => None,
            }
        } else {
            Some(client_terminal_channel_rx.next().await)
        };
        let msg = match result {
            Some(Some(Ok(m))) => m,
            Some(_) => break,
            None => {
                // Idle timeout fired with `pending_finalize` set:
                // drain any ambiguous-but-complete events termwiz held
                // back on the previous frame.
                if let Some(client_connection) = state
                    .connection_table
                    .lock()
                    .unwrap()
                    .get_client_os_api(&web_client_id)
                    .cloned()
                {
                    stdin_session.finalize(&*client_connection, &mut mouse_old_event);
                } else {
                    // No client to send drained events to — clear the
                    // flag so we don't busy-loop the idle timer.
                    stdin_session.clear_pending_finalize();
                }
                continue;
            },
        };
        match msg {
            Message::Binary(buf) => {
                let Some(client_connection) = state
                    .connection_table
                    .lock()
                    .unwrap()
                    .get_client_os_api(&web_client_id)
                    .cloned()
                else {
                    log::error!("Unknown web_client_id: {}", web_client_id);
                    continue;
                };
                parse_stdin(
                    &buf,
                    client_connection.clone(),
                    &mut mouse_old_event,
                    &mut stdin_session,
                );
            },
            Message::Text(msg) => {
                let Some(client_connection) = state
                    .connection_table
                    .lock()
                    .unwrap()
                    .get_client_os_api(&web_client_id)
                    .cloned()
                else {
                    log::error!("Unknown web_client_id: {}", web_client_id);
                    continue;
                };
                parse_stdin(
                    msg.as_bytes(),
                    client_connection.clone(),
                    &mut mouse_old_event,
                    &mut stdin_session,
                );
            },
            Message::Close(_) => {
                break;
            },
            // TODO: support Message::Binary
            _ => {
                log::error!("Unsupported websocket msg type");
            },
        }
    }
    os_input.send_to_server(ClientToServerMsg::ClientExited);
    state
        .connection_table
        .lock()
        .unwrap()
        .remove_client(&web_client_id);
}

fn terminal_metrics_to_ipc(metrics: TerminalMetricsPayload) -> ClientToServerMsg {
    ClientToServerMsg::TerminalPixelDimensions {
        pixel_dimensions: PixelDimensions {
            text_area_size: Some(SizeInPixels {
                width: metrics.text_area_pixel_width,
                height: metrics.text_area_pixel_height,
            }),
            character_cell_size: Some(SizeInPixels {
                width: metrics.cell_pixel_width,
                height: metrics.cell_pixel_height,
            }),
        },
    }
}
