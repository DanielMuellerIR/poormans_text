use gtk::prelude::*;

pub(crate) fn label(text: &str) -> gtk::Label {
    gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .wrap(true)
        .build()
}
pub(crate) fn text_view() -> gtk::TextView {
    gtk::TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .left_margin(12)
        .right_margin(12)
        .top_margin(10)
        .bottom_margin(10)
        .build()
}
pub(crate) fn scroll(child: &impl IsA<gtk::Widget>, min: i32) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .child(child)
        .min_content_height(min)
        .hexpand(true)
        .vexpand(true)
        .build()
}

pub(crate) fn bounded_dropdown(dropdown: &gtk::DropDown) {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
            let label = gtk::Label::builder()
                .xalign(0.0)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .width_chars(18)
                .max_width_chars(32)
                .build();
            item.set_child(Some(&label));
        }
    });
    factory.connect_bind(|_, item| {
        if let Some(item) = item.downcast_ref::<gtk::ListItem>()
            && let Some(text) = item.item().and_downcast::<gtk::StringObject>()
            && let Some(label) = item.child().and_downcast::<gtk::Label>()
        {
            label.set_text(&text.string());
            label.set_tooltip_text(Some(&text.string()));
        }
    });
    dropdown.set_factory(Some(&factory));
    dropdown.set_list_factory(Some(&factory));
}

pub(crate) fn row(parent: &gtk::Box, title: &str, help: &str, child: &impl IsA<gtk::Widget>) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let label = label(title);
    label.set_width_chars(22);
    row.append(&label);
    child.set_hexpand(true);
    child.set_tooltip_text(Some(help));
    label.set_mnemonic_widget(Some(child));
    row.append(child);
    parent.append(&row);
}
