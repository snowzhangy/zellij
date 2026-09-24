use serde::{Deserialize, Serialize};
use zellij_utils::{
    data::PaneId,
    input::config::Config,
    ipc::{MobileStatePayload, TabInventoryBatch, TabSnapshot, TabSnapshotTab, TabUpdate},
    pane_size::Size,
};

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct WebPaneId {
    pub kind: String,
    pub id: u32,
}

impl From<PaneId> for WebPaneId {
    fn from(pane_id: PaneId) -> Self {
        match pane_id {
            PaneId::Terminal(id) => Self {
                kind: "terminal".into(),
                id,
            },
            PaneId::Plugin(id) => Self {
                kind: "plugin".into(),
                id,
            },
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct TabSnapshotTabPayload {
    pub tab_id: usize,
    pub index: usize,
    pub name: String,
    pub active: bool,
    #[serde(default)]
    pub has_bell: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity_at_unix_ms: Option<u64>,
    pub panes: Vec<WebPaneId>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct TabSnapshotPayload {
    pub session_id: String,
    pub sequence: u64,
    pub tabs: Vec<TabSnapshotTabPayload>,
}

impl From<&TabSnapshot> for TabSnapshotPayload {
    fn from(snapshot: &TabSnapshot) -> Self {
        Self {
            session_id: snapshot.session_id.clone(),
            sequence: snapshot.sequence,
            tabs: snapshot
                .tabs
                .iter()
                .map(|tab| TabSnapshotTabPayload {
                    tab_id: tab.tab_id,
                    index: tab.index,
                    name: tab.name.clone(),
                    active: tab.active,
                    has_bell: tab.has_bell,
                    last_activity_at_unix_ms: tab.last_activity_at_unix_ms,
                    panes: tab.pane_ids.iter().copied().map(Into::into).collect(),
                })
                .collect(),
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct TabUpdatePayload {
    pub session_id: String,
    pub sequence: u64,
    pub tab_id: usize,
    pub index: Option<usize>,
    pub name: Option<String>,
    pub active: Option<bool>,
    pub panes: Option<Vec<WebPaneId>>,
    pub closed: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct TabInventoryBatchPayload {
    pub session_id: String,
    pub sequence: u64,
    pub upserts: Vec<TabSnapshotTabPayload>,
    pub closed_tab_ids: Vec<usize>,
}

impl From<TabSnapshotTab> for TabSnapshotTabPayload {
    fn from(tab: TabSnapshotTab) -> Self {
        Self {
            tab_id: tab.tab_id,
            index: tab.index,
            name: tab.name,
            active: tab.active,
            has_bell: tab.has_bell,
            last_activity_at_unix_ms: tab.last_activity_at_unix_ms,
            panes: tab.pane_ids.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<&TabInventoryBatch> for TabInventoryBatchPayload {
    fn from(batch: &TabInventoryBatch) -> Self {
        Self {
            session_id: batch.session_id.clone(),
            sequence: batch.sequence,
            upserts: batch.upserts.iter().map(|tab| tab.clone().into()).collect(),
            closed_tab_ids: batch.closed_tab_ids.clone(),
        }
    }
}

impl From<&TabUpdate> for TabUpdatePayload {
    fn from(update: &TabUpdate) -> Self {
        Self {
            session_id: update.session_id.clone(),
            sequence: update.sequence,
            tab_id: update.tab_id,
            index: update.index,
            name: update.name.clone(),
            active: update.active,
            panes: update
                .pane_ids
                .as_ref()
                .map(|panes| panes.iter().copied().map(Into::into).collect()),
            closed: update.closed,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct WebClientToWebServerControlMessage {
    pub web_client_id: String,
    pub payload: WebClientToWebServerControlMessagePayload,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "type")]
pub enum WebClientToWebServerControlMessagePayload {
    TerminalResize(Size),
    TerminalMetrics(TerminalMetricsPayload),
    ViewportScroll(ViewportScrollPayload),
    SoftKeyboardVisibilityChanged {
        visible: bool,
    },
    NestedSessionFrameFromHost {
        payload_bytes: Vec<u8>,
    },
    RequestSessionList,
    FocusPane {
        pane_id: u32,
        is_plugin: bool,
    },
    NewPaneInTab {
        tab_id: usize,
    },
    NewTab,
    SetMobileRenderPreferences {
        single_pane: bool,
        fit: bool,
    },
    RequestTabSnapshot {
        session_id: String,
    },
    GoToTabById(GoToTabByIdPayload),
    HostTerminalFocusChanged {
        focused: bool,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct TerminalMetricsPayload {
    pub cell_pixel_width: usize,
    pub cell_pixel_height: usize,
    pub text_area_pixel_width: usize,
    pub text_area_pixel_height: usize,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ViewportScrollPayload {
    pub direction: ViewportScrollDirection,
    pub lines: usize,
}

#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct GoToTabByIdPayload {
    #[serde(default)]
    pub session_id: String,
    pub tab_id: usize,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "snake_case")]
pub enum ViewportScrollDirection {
    Up,
    Down,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "type")]
pub enum WebServerToWebClientControlMessage {
    SetConfig(SetConfigPayload),
    InventoryMonitorReady(InventoryMonitorReadyPayload),
    Capabilities(CapabilitiesPayload),
    QueryTerminalSize,
    Log { lines: Vec<String> },
    LogError { lines: Vec<String> },
    SwitchedSession { new_session_name: String },
    SetSoftKeyboard { on: bool },
    MobileState { payload: MobileStatePayload },
    TabSnapshot(TabSnapshotPayload),
    TabUpdate(TabUpdatePayload),
    TabInventoryBatch(TabInventoryBatchPayload),
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct InventoryMonitorReadyPayload {
    pub web_client_id: String,
    pub session_name: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct CapabilitiesPayload {
    pub protocol_version: u32,
    pub server_version: String,
    pub capabilities: Vec<String>,
    pub session_id: Option<String>,
    pub session_name: Option<String>,
}

impl Default for CapabilitiesPayload {
    fn default() -> Self {
        Self {
            protocol_version: 1,
            server_version: zellij_utils::consts::VERSION.to_owned(),
            capabilities: vec![],
            session_id: None,
            session_name: None,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct SetConfigPayload {
    pub font: String,
    pub theme: SetConfigPayloadTheme,
    pub cursor_blink: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor_inactive_style: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor_style: Option<String>,
    pub mac_option_is_meta: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub font_size: Option<u16>,
}

#[derive(Serialize, Deserialize, Debug, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct SetConfigPayloadTheme {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub foreground: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub black: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blue: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bright_black: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bright_blue: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bright_cyan: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bright_green: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bright_magenta: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bright_red: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bright_white: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bright_yellow: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor_accent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cyan: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub green: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub magenta: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub red: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection_background: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection_foreground: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection_inactive_background: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub white: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub yellow: Option<String>,
}

impl From<&Config> for SetConfigPayload {
    fn from(config: &Config) -> Self {
        let font = config.web_client.font.clone();

        let palette = config.theme_config(config.options.theme.as_ref());
        let web_client_theme_from_config = config.web_client.theme.as_ref();

        let mut theme = SetConfigPayloadTheme::default();

        theme.background = web_client_theme_from_config
            .and_then(|theme| theme.background.clone())
            .or_else(|| palette.map(|p| p.text_unselected.background.as_rgb_str()));
        theme.foreground = web_client_theme_from_config
            .and_then(|theme| theme.foreground.clone())
            .or_else(|| palette.map(|p| p.text_unselected.base.as_rgb_str()));
        theme.black = web_client_theme_from_config.and_then(|theme| theme.black.clone());
        theme.blue = web_client_theme_from_config.and_then(|theme| theme.blue.clone());
        theme.bright_black =
            web_client_theme_from_config.and_then(|theme| theme.bright_black.clone());
        theme.bright_blue =
            web_client_theme_from_config.and_then(|theme| theme.bright_blue.clone());
        theme.bright_cyan =
            web_client_theme_from_config.and_then(|theme| theme.bright_cyan.clone());
        theme.bright_green =
            web_client_theme_from_config.and_then(|theme| theme.bright_green.clone());
        theme.bright_magenta =
            web_client_theme_from_config.and_then(|theme| theme.bright_magenta.clone());
        theme.bright_red = web_client_theme_from_config.and_then(|theme| theme.bright_red.clone());
        theme.bright_white =
            web_client_theme_from_config.and_then(|theme| theme.bright_white.clone());
        theme.bright_yellow =
            web_client_theme_from_config.and_then(|theme| theme.bright_yellow.clone());
        theme.cursor = web_client_theme_from_config.and_then(|theme| theme.cursor.clone());
        theme.cursor_accent =
            web_client_theme_from_config.and_then(|theme| theme.cursor_accent.clone());
        theme.cyan = web_client_theme_from_config.and_then(|theme| theme.cyan.clone());
        theme.green = web_client_theme_from_config.and_then(|theme| theme.green.clone());
        theme.magenta = web_client_theme_from_config.and_then(|theme| theme.magenta.clone());
        theme.red = web_client_theme_from_config.and_then(|theme| theme.red.clone());
        theme.selection_background = web_client_theme_from_config
            .and_then(|theme| theme.selection_background.clone())
            .or_else(|| palette.map(|p| p.text_selected.background.as_rgb_str()));
        theme.selection_foreground = web_client_theme_from_config
            .and_then(|theme| theme.selection_foreground.clone())
            .or_else(|| palette.map(|p| p.text_selected.base.as_rgb_str()));
        theme.selection_inactive_background = web_client_theme_from_config
            .and_then(|theme| theme.selection_inactive_background.clone());
        theme.white = web_client_theme_from_config.and_then(|theme| theme.white.clone());
        theme.yellow = web_client_theme_from_config.and_then(|theme| theme.yellow.clone());

        let cursor_blink = config.web_client.cursor_blink;
        let mac_option_is_meta = config.web_client.mac_option_is_meta;
        let cursor_style = config
            .web_client
            .cursor_style
            .as_ref()
            .map(|s| s.to_string());
        let cursor_inactive_style = config
            .web_client
            .cursor_inactive_style
            .as_ref()
            .map(|s| s.to_string());

        let font_size = config.web_client.font_size;

        SetConfigPayload {
            font,
            theme,
            cursor_blink,
            mac_option_is_meta,
            cursor_style,
            cursor_inactive_style,
            font_size,
        }
    }
}
