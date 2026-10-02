/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.tilix.terminal.advpaste;

import std.experimental.logger;
import std.format;
import std.string;

import gdk.Event;
import gdk.Keysyms;

import gio.Settings: GSettings = Settings;

import gtk.Box;
import gtk.CheckButton;
import gtk.Dialog;
import gtk.Label;
import gtk.SpinButton;
import gtk.TextBuffer;
import gtk.TextTagTable;
import gtk.TextView;
import gtk.ScrolledWindow;
import gtk.Widget;
import gtk.Window;

import gx.i18n.l10n;

import gx.tilix.preferences;

string[3] getUnsafePasteMessage() {
    string[3] result = [_("This command is asking for Administrative access to your computer"),
                        _("Copying commands from the internet can be dangerous. "),
                        _("Be sure you understand what each part of this command does.")];

    return result;
}

/**
 * A dialog that is shown to support advance paste. It allows the user
 * to review and edit the content as well as performing various transformations
 * before pasting.
 */
class AdvancedPasteDialog: Dialog {

private:

    GSettings gsSettings;

    TextBuffer buffer;
    CheckButton cbTabsToSpaces;
    SpinButton sbTabWidth;

    CheckButton cbConvertCRLF;
    CheckButton cbReplaceNewlines;
    SpinButton sbLineDelay;

    void createUI(string text, bool unsafe) {
        with (getContentArea()) {
            setMarginLeft(18);
            setMarginRight(18);
            setMarginTop(18);
            setMarginBottom(18);
        }

        Box b = new Box(Orientation.VERTICAL, 6);
        if (unsafe) {
            string[3] msg = getUnsafePasteMessage();
            Label lblUnsafe = new Label("<span weight='bold' size='large'>" ~ msg[0] ~ "</span>\n" ~ msg[1] ~ "\n" ~ msg[2]);
            lblUnsafe.setUseMarkup(true);
            lblUnsafe.setLineWrap(true);
            b.add(lblUnsafe);
            getWidgetForResponse(ResponseType.APPLY).getStyleContext().addClass("destructive-action");
        }

        buffer = new TextBuffer(new TextTagTable());
        buffer.setText(text);
        TextView view = new TextView(buffer);
        view.addOnKeyPress(delegate(Event event, Widget w) {
            uint keyval;
            event.getKeyval(keyval);
            if (keyval == GdkKeysyms.GDK_Return && (event.key.state & GdkModifierType.CONTROL_MASK)) {
                response(GtkResponseType.APPLY);
                return true;
            }
            return false;
        });
        ScrolledWindow sw = new ScrolledWindow(view);
        sw.setShadowType(ShadowType.ETCHED_IN);
        sw.setPolicy(PolicyType.AUTOMATIC, PolicyType.AUTOMATIC);
        sw.setHexpand(true);
        sw.setVexpand(true);
        sw.setSizeRequest(400, 140);

        b.add(sw);

        Label lblTransform = new Label(format("<b>%s</b>", _("Transform")));
        lblTransform.setUseMarkup(true);
        lblTransform.setHalign(GtkAlign.START);
        lblTransform.setMarginTop(6);
        b.add(lblTransform);

        //Tabs to Spaces
        Box bTabs = new Box(Orientation.HORIZONTAL, 6);
        cbTabsToSpaces = new CheckButton(_("Convert spaces to tabs"));
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_REPLACE_TABS_KEY, cbTabsToSpaces, "active", GSettingsBindFlags.DEFAULT);
        bTabs.add(cbTabsToSpaces);

        sbTabWidth = new SpinButton(0, 32, 1);
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_SPACE_COUNT_KEY, sbTabWidth.getAdjustment(), "value", GSettingsBindFlags.DEFAULT);
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_REPLACE_TABS_KEY, sbTabWidth, "sensitive", GSettingsBindFlags.DEFAULT);
        bTabs.add(sbTabWidth);

        b.add(bTabs);

        cbConvertCRLF = new CheckButton(_("Convert CRLF and CR to LF"));
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_REPLACE_CRLF_KEY, cbConvertCRLF, "active", GSettingsBindFlags.DEFAULT);
        b.add(cbConvertCRLF);

        cbReplaceNewlines = new CheckButton(_("Replace newlines with spaces"));
        cbReplaceNewlines.setTooltipText(_("Joins the lines into one, i.e. to paste a column as a list of arguments"));
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_REPLACE_NEWLINES_KEY, cbReplaceNewlines, "active", GSettingsBindFlags.DEFAULT);
        b.add(cbReplaceNewlines);

        Box bDelay = new Box(Orientation.HORIZONTAL, 6);
        bDelay.add(new Label(_("Delay between lines (ms)")));
        sbLineDelay = new SpinButton(0, 10000, 50);
        sbLineDelay.setTooltipText(_("Sends a line at a time, as if typed, for devices that can't take a large paste at once. 0 pastes everything at once."));
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_LINE_DELAY_KEY, sbLineDelay.getAdjustment(), "value", GSettingsBindFlags.DEFAULT);
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_REPLACE_NEWLINES_KEY, sbLineDelay, "sensitive", GSettingsBindFlags.INVERT_BOOLEAN);
        bDelay.add(sbLineDelay);
        b.add(bDelay);

        getContentArea().add(b);
    }

    string transform() {
        string text = buffer.getText();
        if (gsSettings.getBoolean(SETTINGS_ADVANCED_PASTE_REPLACE_TABS_KEY)) {
            text = text.detab(gsSettings.getInt(SETTINGS_ADVANCED_PASTE_SPACE_COUNT_KEY));
        }
        if (gsSettings.getBoolean(SETTINGS_ADVANCED_PASTE_REPLACE_CRLF_KEY)) {
            text = text.replace("\r\n", "\n");
            text = text.replace("\r", "\n");

        }
        if (gsSettings.getBoolean(SETTINGS_ADVANCED_PASTE_REPLACE_NEWLINES_KEY)) {
            text = joinLines(text);
        }
        return text;
    }

public:
    this(Window parent, string text, bool unsafe) {
        super(_("Advanced Paste"), parent, GtkDialogFlags.MODAL + GtkDialogFlags.USE_HEADER_BAR, [_("Paste"), _("Cancel")], [GtkResponseType.APPLY, GtkResponseType.CANCEL]);
        setTransientFor(parent);
        setDefaultResponse(GtkResponseType.APPLY);
        gsSettings = new GSettings(SETTINGS_ID);
        createUI(text, unsafe);
    }

    @property string text() {
        return transform();
    }
}

/**
 * Joins the lines of text into one separated by single spaces, i.e. to paste a
 * column of names as a list of arguments. Each line is trimmed and empty lines
 * are skipped, so the result has no newline and nothing runs on paste.
 */
string joinLines(string text) {
    import std.algorithm : filter, map;
    import std.array : join;
    import std.string : lineSplitter, strip;

    return text.lineSplitter.map!(line => line.strip()).filter!(line => line.length > 0).join(" ");
}

/**
 * Splits text into the pieces sent for a paste with a delay between lines,
 * each line keeping its line ending so it runs as if typed.
 */
string[] pasteLines(string text) {
    import std.array : array;
    import std.string : KeepTerminator, lineSplitter;

    return text.lineSplitter!(KeepTerminator.yes).array;
}

unittest {
    assert(joinLines("alpha\nbeta\ngamma\n") == "alpha beta gamma");
    assert(joinLines("  one \r\n\n two\t\r\nthree") == "one two three");
    assert(joinLines("single") == "single");
    assert(joinLines("\n\n") == "");
    assert(joinLines("") == "");

    assert(pasteLines("interface eth0\n ip address 10.0.0.1\n") == ["interface eth0\n", " ip address 10.0.0.1\n"]);
    // A last line without a newline is sent without one, as copied
    assert(pasteLines("a\r\nb") == ["a\r\n", "b"]);
    assert(pasteLines("") == []);
}
