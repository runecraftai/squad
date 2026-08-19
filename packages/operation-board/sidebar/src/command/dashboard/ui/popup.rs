//! Shared popup rendering primitives.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::Line,
    widgets::{Block, Clear, Widget},
};

use super::theme::ThemePalette;

/// Center a rect of given dimensions within an area, saturating at terminal edges.
pub fn centered_rect(area: Rect, width: u16, height: u16) -> Rect {
    let popup_width = width.min(area.width);
    let popup_height = height.min(area.height);
    Rect {
        x: area.width.saturating_sub(popup_width) / 2,
        y: area.height.saturating_sub(popup_height) / 2,
        width: popup_width,
        height: popup_height,
    }
}

/// Create a bordered rounded block with help border styling and an optional bold title.
pub fn popup_block(title: Option<&'static str>, palette: &ThemePalette) -> Block<'static> {
    use ratatui::text::Span;
    use ratatui::widgets::BorderType;

    let mut block = Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(palette.help_border));

    if let Some(title) = title {
        block = block.title(Line::from(vec![
            Span::styled(" ", Style::default()),
            Span::styled(
                title,
                Style::default()
                    .fg(palette.header)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" ", Style::default()),
        ]));
    }

    block
}

/// Render a Clear widget followed by the content widget in the same area.
pub fn render_popup<W: Widget>(f: &mut Frame, area: Rect, widget: W) {
    f.render_widget(Clear, area);
    f.render_widget(widget, area);
}
