/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.tilix.bookmark.manager;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime.systime : Clock;
import std.experimental.logger;
import std.file;
import std.format : format;
import std.json;
import std.path;
import std.uuid;

import gdk.Pixbuf;
import gdk.RGBA;
import gdk.Screen;

import glib.ShellUtils;
import glib.Util;

import gtk.IconInfo;
import gtk.IconTheme;
import gtk.StyleContext;
import gtk.Widget;

import gx.i18n.l10n;

import gx.tilix.constants;

enum BookmarkType {
    FOLDER,
    PATH,
    REMOTE,
    COMMAND}

class BookmarkException: Exception {

    this(string message) {
        super(message);
    }
}

interface Bookmark {

    JSONValue serialize(FolderBookmark parent);
    void deserialize(JSONValue value);

    @property BookmarkType type();

    /**
     * Parent of the bookmark, will be null in case
     * of root.
     */
    @property FolderBookmark parent();

    @property void parent(FolderBookmark parent);

    /**
     * Bookmark name
     */
    @property string name();

    @property void name(string value);

    /**
     * Unique identifier for the bookmark
     */
    @property string uuid();

    /**
     * The command to insert into the terminal
     * for this bookmark.
     */
    @property string terminalCommand();

}

abstract class AbstractBookmark: Bookmark {
private:
    string _name;
    string _uuid;

    FolderBookmark _parent;
public:

    this() {
        _uuid = randomUUID().toString();
    }

    this(string name) {
        this();
        this._name = name;
    }

    @property FolderBookmark parent() {
        return _parent;
    }

    @property void parent(FolderBookmark value) {
        if (_parent != value) {
            _parent = value;
            bmMgr.changed;
        }
    }

    @property string name() {
        return _name;
    }

    @property void name(string value) {
        if (_name != value) {
            _name = value;
            bmMgr.changed();
        }
    }

    @property string uuid() {
        return _uuid;
    }

    JSONValue serialize(FolderBookmark parent) {
        JSONValue value = [NODE_BOOKMARK_TYPE : to!string(type())];
        value[NODE_NAME] = name;
        _parent = parent;
        return value;
    }

    void deserialize(JSONValue value) {
        _name = value[NODE_NAME].str();
    }
}

/**
 * Folder that holds a list of Bookmarks
 */
class FolderBookmark: AbstractBookmark {

private:

    enum NODE_LIST = "list";

    Bookmark[] list;

package:

    void add(Bookmark bm) {
        list ~= bm;
        bm.parent = this;
        bmMgr.changed();
    }

    void remove(Bookmark bm) {
        import gx.util.array: remove;
        list.remove(bm);
        bm.parent = null;
        bmMgr.changed();
    }

    void insertBefore(Bookmark target, Bookmark bm) {
        ptrdiff_t index = list.countUntil(target);
        if (index < 0) {
            throw new BookmarkException("Target was not located in the folder");
        }
        list.insertInPlace(index, bm);
        bm.parent = this;
        bmMgr.changed();
    }

    void insertAfter(Bookmark target, Bookmark bm) {
        ptrdiff_t index = list.countUntil(target);
        if (index < 0) {
            throw new BookmarkException("Target was not located in the folder");
        }
        if (index < list.length - 1) {
            list.insertInPlace(index + 1, bm);
        } else {
            list ~= bm;
        }
        bm.parent = this;
        bmMgr.changed();
    }

public:

    this() {
        super();
    }

    this(string name) {
        super(name);
    }

    @property BookmarkType type() {
        return BookmarkType.FOLDER;
    }

    int opApply ( int delegate ( ref Bookmark x ) dg ) {
        int result = 0;
        foreach (ref x; list) {
            result = dg(x);
            if (result) break;
        }
        return result;
    }

    override JSONValue serialize(FolderBookmark parent) {
        // LDC 1.0.0 breaks on super call to abstract class, see #769
        JSONValue value = [NODE_BOOKMARK_TYPE : to!string(type())];
        value[NODE_NAME] = name;
        _parent = parent;

        //JSONValue value = super.serialize(parent);

        JSONValue[] jsonList = [];
        foreach(item; list) {
            jsonList ~= item.serialize(this);
        }
        value[NODE_LIST] = jsonList;
        return value;
    }

    override void deserialize(JSONValue value) {
        super.deserialize(value);
        JSONValue[] jsonList = value[NODE_LIST].array();
        foreach(item; jsonList) {
            try {
                BookmarkType type = to!BookmarkType(item[NODE_BOOKMARK_TYPE].str());
                Bookmark bm = bmMgr.createBookmark(type);
                bm.deserialize(item);
                bmMgr.add(this, bm);
            } catch (Exception e) {
                error(_("Error deserializing bookmark"));
                error(e);
                // The bookmark will be missing when the file is next saved
                bmMgr._loadErrors = true;
            }
        }
    }

    @property string terminalCommand() {
        return "";
    }
}

class PathBookmark: AbstractBookmark {
private:
    string _path;

    enum NODE_PATH = "path";

public:

    this() {
        super();
    }

    this(string name, string path) {
        super(name);
        _path = path;
    }

    @property BookmarkType type() {
        return BookmarkType.PATH;
    }

    @property string path() {
        return _path;
    }

    @property void path(string value) {
        if (_path != value) {
            _path = value;
            bmMgr.changed();
        }
    }

    override JSONValue serialize(FolderBookmark parent) {
        // LDC 1.0.0 breaks on super call to abstract class, see #769
        JSONValue value = [NODE_BOOKMARK_TYPE : to!string(type())];
        value[NODE_NAME] = name;
        _parent = parent;

        //JSONValue value = super.serialize(parent);
        value[NODE_PATH] = _path;
        return value;
    }

    override void deserialize(JSONValue value) {
        super.deserialize(value);
        _path = value[NODE_PATH].str();
    }

    @property string terminalCommand() {
        return "cd " ~ ShellUtils.shellQuote(_path);
    }
}

/**
 * The type of protocol a remote bookmark uses
 */
enum ProtocolType {SSH, TELNET, FTP, SFTP}

/**
 * represents a bookmark to a remote system
 */
class RemoteBookmark: AbstractBookmark {
private:
    ProtocolType _protocolType;
    string _host;
    uint _port;
    string _user;
    string _params;
    string _path;
    string _command;

    enum NODE_HOST = "host";
    enum NODE_PORT = "port";
    enum NODE_USER = "user";
    enum NODE_PARAMS = "params";
    enum NODE_PROTOCOL_TYPE = "protocolType";
    enum NODE_COMMAND = "command";

public:

    this() {
        super();
    }

    @property BookmarkType type() {
        return BookmarkType.REMOTE;
    }

    @property string host() {
        return _host;
    }

    @property void host(string value) {
        if (_host != value) {
            _host = value;
            bmMgr.changed();
        }
    }

    @property uint port() {
        return _port;
    }

    @property void port(uint value) {
        if (_port != value) {
            _port = value;
            bmMgr.changed();
        }
    }

    @property string user() {
        return _user;
    }

    @property void user(string value) {
        if (_user != value) {
            _user = value;
            bmMgr.changed();
        }
    }

    @property string params() {
        return _params;
    }

    @property void params(string value) {
        if (_params != value) {
            _params = value;
            bmMgr.changed();
        }
    }

    @property ProtocolType protocolType() {
        return _protocolType;
    }

    @property void protocolType(ProtocolType value) {
        if (_protocolType != value) {
            _protocolType = value;
            bmMgr.changed();
        }
    }

    @property string command() {
        return _command;
    }

    @property void command(string value) {
        if (_command != value) {
            _command = value;
            bmMgr.changed();
        }
    }

    override JSONValue serialize(FolderBookmark parent) {
        // LDC 1.0.0 breaks on super call to abstract class, see #769
        JSONValue value = [NODE_BOOKMARK_TYPE : to!string(type())];
        value[NODE_NAME] = name;
        _parent = parent;

        //JSONValue value = super.serialize(parent);
        value[NODE_HOST] = _host;
        value[NODE_PORT] = _port;
        value[NODE_USER] = _user;
        value[NODE_PARAMS] = _params;
        value[NODE_PROTOCOL_TYPE] = to!string(protocolType);
        value[NODE_COMMAND] = _command;
        return value;
    }

    override void deserialize(JSONValue value) {
        super.deserialize(value);
        _host = value[NODE_HOST].str;
        // Serialized as unsigned, but parsing JSON text gives a signed integer
        JSONValue port = value[NODE_PORT];
        _port = to!uint(port.type == JSONType.uinteger ? port.uinteger : port.integer);
        _user = value[NODE_USER].str;
        _params = value[NODE_PARAMS].str;
        _protocolType = to!ProtocolType(value[NODE_PROTOCOL_TYPE].str);
        _command = value[NODE_COMMAND].str;
    }

    @property string terminalCommand() {
        string result;
        switch(_protocolType) {
            case ProtocolType.SSH:
                result = "ssh";
                if (params.length > 0) result ~= " " ~ params;
                if (user.length > 0) result ~= " " ~ user ~ "@" ~ host;
                else result ~= " " ~ host;
                if (port > 0) result ~= " -p " ~ to!string(port);
                if (command.length > 0) result ~= " " ~ ShellUtils.shellQuote(command);
                break;
            case ProtocolType.TELNET:
                result = "telnet";
                if (params.length > 0) result ~= " " ~ params;
                result ~= " " ~ host;
                if (port > 0) result ~= " " ~ to!string(port);
                break;
            case ProtocolType.FTP: .. case ProtocolType.SFTP:
                result = "ftp";
                if (_protocolType == ProtocolType.SFTP) {
                    result = "s" ~ result;
                }
                if (params.length > 0) result ~= " " ~ params;
                if (user.length > 0) result ~= " " ~ user ~ "@" ~ host;
                else result ~= " " ~ host;
                if (port > 0) result ~= " " ~ to!string(port);
                break;
            default:
        }
        return result;
    }
}

/**
 * Bookmark that represents an arbitrary executable command.
 */
class CommandBookmark: AbstractBookmark {
private:
    string _command;

    enum NODE_COMMAND = "command";

public:
    this() {
        super();
    }

    @property BookmarkType type() {
        return BookmarkType.COMMAND;
    }

    @property string command() {
        return _command;
    }

    @property void command(string value) {
        if (_command != value) {
            _command = value;
            bmMgr.changed();
        }
    }

    override JSONValue serialize(FolderBookmark parent) {
        // LDC 1.0.0 breaks on super call to abstract class, see #769
        JSONValue value = [NODE_BOOKMARK_TYPE : to!string(type())];
        value[NODE_NAME] = name;
        _parent = parent;

        //JSONValue value = super.serialize(parent);
        value[NODE_COMMAND] = _command;
        return value;
    }

    override void deserialize(JSONValue value) {
        super.deserialize(value);
        _command = value[NODE_COMMAND].str;
    }

    @property string terminalCommand() {
        return _command;
    }

}

/**
 * Manages all the bookmarks for tilix, this is
 * intended to run as a singleton.
 */
class BookmarkManager {
private:
    enum BOOKMARK_FILE = "bookmarks.json";

    FolderBookmark _root;
    Bookmark[string] bookmarks;

    bool _changed = false;
    // Set when some or all bookmarks in the file could not be loaded
    bool _loadErrors = false;

    /**
     * Remove all references to folder and it's children
     * from bookmarks associative array. Could also be used
     * for other cleanup but not needed at this time.
     */
    void clear(FolderBookmark fb) {
        if (fb is null) return;
        foreach(bm; fb) {
            if (bm.uuid in bookmarks) bookmarks.remove(bm.uuid);
            FolderBookmark child = cast(FolderBookmark) bm;
            if (child !is null) clear(child);
        }
    }

public:
    this() {
        _root = new FolderBookmark(_("Root"));
    }

    Bookmark createBookmark(BookmarkType type) {
        tracef("Creating bookmark %s", type);
        final switch (type) {
            case BookmarkType.FOLDER:
                return new FolderBookmark();
            case BookmarkType.PATH:
                return new PathBookmark();
            case BookmarkType.REMOTE:
                return new RemoteBookmark();
            case BookmarkType.COMMAND:
                return new CommandBookmark();
        }
    }

    void add(FolderBookmark fb, Bookmark bm) {
        fb.add(bm);
        bookmarks[bm.uuid] = bm;
    }

    void remove(Bookmark bm) {
        if (bm is null || bm.parent is null) {
            errorf("Unexpected error, bookmark %s is null or bookmark has no parent", bm is null ? "(null)" : bm.name);
            return;
        }
        tracef("Removing %s from folder %s", bm.name, bm.parent.name);
        bm.parent.remove(bm);
        bookmarks.remove(bm.uuid);
        clear(cast(FolderBookmark) bm);
    }

    void moveBefore(Bookmark target, Bookmark source) {
        checkMove(target, source);
        source.parent.remove(source);
        target.parent.insertBefore(target, source);
    }

    void moveAfter(Bookmark target, Bookmark source) {
        checkMove(target, source);
        source.parent.remove(source);
        target.parent.insertAfter(target, source);
    }

    void moveInto(FolderBookmark target, Bookmark source) {
        checkMove(target, source);
        source.parent.remove(source);
        target.add(source);
    }

    /**
     * Throws a BookmarkException if moving source next to or into target
     * would place source inside itself, i.e. a folder into its own sub-tree.
     * That would detach the folder from the root, losing it when saved, or
     * make it contain itself and recurse forever when serialized.
     */
    void checkMove(Bookmark target, Bookmark source) {
        for (Bookmark current = target; current !is null; current = current.parent) {
            if (current is source) {
                throw new BookmarkException(format("Bookmark '%s' cannot be moved into itself", source.name));
            }
        }
    }

    string localize(BookmarkType type) {
        return _(localizedBookmarks[cast(uint)type]);
    }

    Bookmark get(string uuid) {
        if (uuid in bookmarks) {
            return bookmarks[uuid];
        } else {
            return null;
        }
    }

    void save() {
        string path = buildPath(Util.getUserConfigDir(), APPLICATION_CONFIG_FOLDER);
        if (!exists(path)) {
            mkdirRecurse(path);
        }
        save(buildPath(path, BOOKMARK_FILE));
    }

    void save(string filename) {
        string json = root.serialize(null).toPrettyString();
        // Write to a temporary file and rename it so a crash or full disk
        // part way through writing never leaves a truncated bookmarks file
        string temp = filename ~ ".tmp";
        try {
            write(temp, json);
            rename(temp, filename);
        } catch (Exception e) {
            error(_("Could not save bookmarks due to unexpected error"));
            error(e);
            if (exists(temp)) tryRemove(temp);
        }
    }

    void load() {
        load(buildPath(Util.getUserConfigDir(), APPLICATION_CONFIG_FOLDER, BOOKMARK_FILE));
    }

    void load(string filename) {
        _loadErrors = false;
        if (exists(filename)) {
            try {
                string json = readText(filename);
                JSONValue value = parseJSON(json);
                _root.deserialize(value);
            } catch (Exception e) {
                error(_("Could not load bookmarks due to unexpected error"));
                error(e);
                _loadErrors = true;
            }
            // The next save would overwrite the bookmarks that could not be
            // loaded, keep a copy of the original file so they can be recovered
            if (_loadErrors) backup(filename);
        }
        _changed = false;
    }

    void backup(string filename) {
        string timestamp = Clock.currTime().toISOString().split(".")[0];
        string backupFilename = filename ~ "." ~ timestamp ~ ".bak";
        try {
            std.file.copy(filename, backupFilename);
            errorf("Bookmarks file could not be fully loaded, original saved as '%s'", backupFilename);
        } catch (Exception e) {
            errorf("Could not back up bookmarks file '%s'", filename);
            error(e);
        }
    }

    void tryRemove(string filename) {
        try {
            std.file.remove(filename);
        } catch (Exception e) {
            error(e);
        }
    }

    void changed() {
        _changed = true;
    }

    @property FolderBookmark root() {
        return _root;
    }

    @property bool hasChanged() {
        return _changed;
    }
}


void initBookmarkManager() {
    bmMgr = new BookmarkManager();
}

Pixbuf[] getBookmarkIcons(Widget widget) {
    if (bmIcons.length > 0) return bmIcons;
    string[] names = ["folder-symbolic","mark-location-symbolic","folder-remote-symbolic", "application-x-executable-symbolic"];
    Pixbuf[] icons;
    IconTheme iconTheme = IconTheme.getForScreen(Screen.getDefault());
    if (iconTheme is null) {
        error("IconTheme could not be loaded");
        return [null, null, null, null];
    }

    RGBA fg;
    if (!widget.getStyleContext().lookupColor("theme_fg_color", fg)) {
        error("theme_fg_color could not be loaded");
        return [null, null, null, null];
    }
    foreach(name; names) {
        IconInfo iconInfo = iconTheme.lookupIcon(name, 16, IconLookupFlags.GENERIC_FALLBACK);
        bool wasSymbolic;
        icons ~= iconInfo.loadSymbolic(fg, null, null, null, wasSymbolic);
    }
    bmIcons = icons;
    return icons;
}

/**
 * Clears the bookmark icon cache.
 */
void clearBookmarkIconCache() {
    bmIcons.length = 0;
}

/**
 * Instance variable for the BookmarkManager. It is the responsibility of the
 * application to initialize this. Debated about using a Java like singleton pattern
 * but let's keep it simple for now.
 *
 * Also note that this variable is meant to be accessed only from the GTK main thread
 * and hence is not declared as shared.
 */
BookmarkManager bmMgr;


private:
    enum NODE_NAME = "name";
    enum NODE_BOOKMARK_TYPE = "type";

    string[5] localizedBookmarks = [N_("Folder"), N_("Path"), N_("Remote"), N_("Command")];
    Pixbuf[] bmIcons;

unittest {
    initBookmarkManager();
    FolderBookmark root = bmMgr.root;

    PathBookmark pb = new PathBookmark("Home", "/home/gnunn");
    root.add(pb);

    pb = new PathBookmark("Development", "/home/gnunn/Development");
    root.add(pb);

    JSONValue json = root.serialize(null);

    import std.stdio;
    writeln(json.toPrettyString());

    FolderBookmark test = new FolderBookmark();
    test.deserialize(json);
}
// Path bookmark commands reach the exact directory even with shell special characters
unittest {
    import std.process : Config, execute, thisProcessID;

    initBookmarkManager();
    string markerName = "tilix-bm-marker-" ~ to!string(thisProcessID());
    string dir = buildPath(tempDir(), "tilix-bm Tom's $HOME; touch " ~ markerName ~ " & `touch " ~ markerName ~ "`");
    mkdirRecurse(dir);
    scope(exit) rmdirRecurse(dir);

    PathBookmark pb = new PathBookmark("Odd", dir);
    auto result = execute(["/bin/sh", "-c", pb.terminalCommand ~ " && pwd"], null, Config.none, size_t.max, tempDir());
    assert(result.status == 0, result.output);
    assert(result.output == dir ~ "\n", result.output);
    assert(!exists(buildPath(tempDir(), markerName)));
}

// The SSH remote command reaches ssh as a single argument
unittest {
    import std.process : execute;

    // Returns the arguments the shell passes to the command, each in []
    string arguments(string command) {
        auto result = execute(["/bin/sh", "-c", "set -- " ~ command.findSplitAfter(" ")[1] ~ "; printf '[%s]' \"$@\""]);
        assert(result.status == 0, result.output);
        return result.output;
    }

    initBookmarkManager();
    RemoteBookmark rb = new RemoteBookmark();
    rb.protocolType = ProtocolType.SSH;
    rb.host = "example.com";
    rb.user = "me";
    rb.port = 2222;
    rb.params = "-A";
    rb.command = "echo \"$HOME\" it's; ls";
    assert(rb.terminalCommand.startsWith("ssh "));
    assert(arguments(rb.terminalCommand) == "[-A][me@example.com][-p][2222][echo \"$HOME\" it's; ls]");

    rb.user = "";
    rb.port = 0;
    rb.params = "";
    rb.command = "";
    assert(rb.terminalCommand == "ssh example.com");
}

// Serializing and deserializing keeps a nested tree intact
unittest {
    initBookmarkManager();
    FolderBookmark root = bmMgr.root;
    FolderBookmark folder = new FolderBookmark("Servers");
    bmMgr.add(root, folder);
    bmMgr.add(folder, new PathBookmark("Logs", "/var/log"));
    RemoteBookmark rb = new RemoteBookmark();
    rb.name = "Web";
    rb.protocolType = ProtocolType.SSH;
    rb.host = "web.example.com";
    rb.user = "admin";
    rb.port = 22;
    rb.command = "uptime";
    bmMgr.add(folder, rb);
    CommandBookmark cb = new CommandBookmark();
    cb.name = "Top";
    cb.command = "top -d 1";
    bmMgr.add(root, cb);

    JSONValue json = root.serialize(null);
    // Both directly and via text as when saved to and loaded from a file
    foreach (source; [json, parseJSON(json.toString())]) {
        FolderBookmark copy = new FolderBookmark();
        copy.deserialize(source);
        assert(copy.list.length == 2);
        FolderBookmark copyFolder = cast(FolderBookmark) copy.list[0];
        assert(copyFolder.list.length == 2);
        RemoteBookmark copyRemote = cast(RemoteBookmark) copyFolder.list[1];
        assert(copyRemote.host == "web.example.com" && copyRemote.port == 22 && copyRemote.command == "uptime");
        assert(parseJSON(copy.serialize(null).toString()) == parseJSON(json.toString()));
    }
}

// Loading and saving never loses the bookmarks file
unittest {
    import std.process : thisProcessID;

    string dir = buildPath(tempDir(), "tilix-bm-test-" ~ to!string(thisProcessID()));
    mkdirRecurse(dir);
    scope(exit) rmdirRecurse(dir);
    string file = buildPath(dir, "bookmarks.json");

    string[] backups() {
        return dirEntries(dir, "bookmarks.json.*.bak", SpanMode.shallow).map!(e => e.name).array;
    }

    // A corrupt file is backed up and left untouched
    write(file, "{ not json");
    initBookmarkManager();
    bmMgr.load(file);
    assert(backups().length == 1);
    assert(readText(backups()[0]) == "{ not json");
    assert(readText(file) == "{ not json");
    std.file.remove(backups()[0]);

    // With one bad entry the good one still loads and the file is backed up
    string partial = `{"name":"Root","type":"FOLDER","list":[` ~
        `{"name":"Good","type":"PATH","path":"/tmp"},{"name":"Bad","type":"PATH"}]}`;
    write(file, partial);
    initBookmarkManager();
    bmMgr.load(file);
    assert(bmMgr.root.list.length == 1);
    assert(bmMgr.root.list[0].name == "Good");
    assert(backups().length == 1);
    assert(readText(backups()[0]) == partial);
    std.file.remove(backups()[0]);

    // Saving replaces the file and leaves no temporary file behind
    bmMgr.save(file);
    assert(parseJSON(readText(file))["list"].array.length == 1);
    assert(!exists(file ~ ".tmp"));

    // A good file loads without a backup
    initBookmarkManager();
    bmMgr.load(file);
    assert(bmMgr.root.list.length == 1);
    assert(backups().length == 0);
    assert(!bmMgr.hasChanged());

    // A missing file is not an error
    initBookmarkManager();
    bmMgr.load(buildPath(dir, "missing.json"));
    assert(bmMgr.root.list.length == 0);
    assert(backups().length == 0);
}

// A folder can't be moved into itself or its own sub-tree
unittest {
    import std.exception : assertThrown;

    initBookmarkManager();
    FolderBookmark root = bmMgr.root;
    FolderBookmark a = new FolderBookmark("A");
    bmMgr.add(root, a);
    FolderBookmark b = new FolderBookmark("B");
    bmMgr.add(a, b);
    PathBookmark p = new PathBookmark("P", "/");
    bmMgr.add(b, p);

    assertThrown!BookmarkException(bmMgr.moveInto(a, a));
    assertThrown!BookmarkException(bmMgr.moveInto(b, a));
    assertThrown!BookmarkException(bmMgr.moveBefore(p, a));
    assertThrown!BookmarkException(bmMgr.moveAfter(b, a));
    assertThrown!BookmarkException(bmMgr.moveBefore(a, a));
    // The tree is unchanged
    assert(a.parent is root && b.parent is a && p.parent is b);

    // Valid moves still work
    bmMgr.moveInto(root, p);
    assert(p.parent is root);
    bmMgr.moveBefore(a, b);
    assert(b.parent is root);
    assert(root.list == [cast(Bookmark) b, a, p]);
}
