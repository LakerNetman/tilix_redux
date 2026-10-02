/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.tilix.searchprovider;

import std.algorithm;
import std.array;
import std.conv;
import std.experimental.logger;
import std.string;
import std.uni : toLower;

import gio.c.functions;
import gio.c.types;

import glib.c.functions;
import glib.c.types;

import gobject.c.types;

/**
 * GNOME Shell search provider, see
 * https://developer.gnome.org/documentation/tutorials/search-provider.html
 *
 * The shell calls the org.gnome.Shell.SearchProvider2 interface on the
 * application's bus name, activating Tilix if needed. The object is exported
 * from GApplication's dbus_register so it exists before the bus name is owned,
 * method calls queued during activation would otherwise fail.
 */

enum SEARCH_PROVIDER_PATH = "/com/gexperts/Tilix/SearchProvider";
enum SEARCH_PROVIDER_INTERFACE = "org.gnome.Shell.SearchProvider2";

/**
 * Something that can be found, i.e. an open terminal, a bookmark or a session file
 */
struct SearchItem {
    string id;
    string name;
    string description;
    // Themed icon name
    string icon;
    // Text the search terms are matched against
    string[] haystack;
}

/**
 * Implemented by the application to supply the items and act on them
 */
interface SearchProviderHost {
    SearchItem[] searchItems();
    void activateResult(string id, uint timestamp);
    void launchSearch(string[] terms, uint timestamp);
}

/**
 * The kinds of result, the kind is the prefix of the result id
 */
enum ResultKind {TERMINAL, BOOKMARK, SESSION}

string resultId(ResultKind kind, string key) {
    final switch (kind) {
        case ResultKind.TERMINAL: return "terminal:" ~ key;
        case ResultKind.BOOKMARK: return "bookmark:" ~ key;
        case ResultKind.SESSION: return "session:" ~ key;
    }
}

/**
 * Splits a result id made by resultId, returns false if it isn't one
 */
bool parseResultId(string id, out ResultKind kind, out string key) {
    foreach (k; [ResultKind.TERMINAL, ResultKind.BOOKMARK, ResultKind.SESSION]) {
        string prefix = resultId(k, "");
        if (id.startsWith(prefix) && id.length > prefix.length) {
            kind = k;
            key = id[prefix.length .. $];
            return true;
        }
    }
    return false;
}

/**
 * Whether every term is found, ignoring case, in at least one of the haystack strings.
 * This is how GNOME's own providers match, so "dev git" finds a terminal titled
 * "git" in ~/dev. No terms matches nothing.
 */
bool matchesTerms(const string[] terms, const string[] haystack) {
    bool any = false;
    foreach (term; terms) {
        string t = term.strip().toLower();
        if (t.length == 0) continue;
        any = true;
        if (!haystack.any!(h => h.toLower().canFind(t))) return false;
    }
    return any;
}

/**
 * Ids of the items matching the terms, in the order of the items
 */
string[] matchingIds(const SearchItem[] items, const string[] terms) {
    string[] result;
    foreach (item; items) {
        if (matchesTerms(terms, item.haystack)) result ~= item.id;
    }
    return result;
}

/**
 * Shortens a path in the home folder to start with ~
 */
string tildePath(string path, string home) {
    home = home.stripRight("/");
    if (home.length == 0) return path;
    if (path == home) return "~";
    if (path.startsWith(home ~ "/")) return "~" ~ path[home.length .. $];
    return path;
}

/**
 * Turns Pango markup, as used for terminal titles, into plain text
 */
string stripMarkup(string markup) {
    string result;
    size_t i = 0;
    while (i < markup.length) {
        char c = markup[i];
        if (c == '<') {
            ptrdiff_t end = markup.indexOf('>', i);
            if (end < 0) {
                result ~= markup[i .. $];
                break;
            }
            i = end + 1;
        } else if (c == '&') {
            ptrdiff_t end = markup.indexOf(';', i);
            string entity = end < 0 ? "" : markup[i + 1 .. end];
            string decoded = decodeEntity(entity);
            if (decoded is null) {
                result ~= c;
                i++;
            } else {
                result ~= decoded;
                i = end + 1;
            }
        } else {
            result ~= c;
            i++;
        }
    }
    return result;
}

private string decodeEntity(string entity) {
    switch (entity) {
        case "amp": return "&";
        case "lt": return "<";
        case "gt": return ">";
        case "quot": return "\"";
        case "apos": return "'";
        default:
            if (entity.length < 2 || entity[0] != '#') return null;
            try {
                uint code = entity[1] == 'x' ? to!uint(entity[2 .. $], 16) : to!uint(entity[1 .. $]);
                return to!string(cast(dchar) code);
            } catch (Exception e) {
                return null;
            }
    }
}

/**
 * Exports the search provider for the application. This replaces the dbus_register
 * and dbus_unregister virtual functions of the application's class, chaining to
 * the originals, as GtkD can't override them in a subclass. It must be called
 * before the application is registered, i.e. before run.
 */
void installSearchProvider(GApplication* app, SearchProviderHost host) {
    _host = host;
    if (_installed) return;
    _installed = true;
    GApplicationClass* klass = cast(GApplicationClass*) (cast(GTypeInstance*) app).gClass;
    parentRegister = klass.dbusRegister;
    parentUnregister = klass.dbusUnregister;
    klass.dbusRegister = &onDBusRegister;
    klass.dbusUnregister = &onDBusUnregister;
}

/**
 * Handles a call to a SearchProvider2 method. Returns the reply, which is
 * floating, or null for an unknown method.
 */
GVariant* handleSearchMethod(SearchProviderHost host, string method, GVariant* parameters) {
    switch (method) {
        case "GetInitialResultSet":
            return replyStrv(matchingIds(host.searchItems(), childStrv(parameters, 0)));
        case "GetSubsearchResultSet":
            // Search again rather than narrowing the previous results, terminals may
            // have changed since. It's cheap as everything is already in memory.
            return replyStrv(matchingIds(host.searchItems(), childStrv(parameters, 1)));
        case "GetResultMetas":
            return replyMetas(host.searchItems(), childStrv(parameters, 0));
        case "ActivateResult":
            host.activateResult(childString(parameters, 0), childUint(parameters, 2));
            return g_variant_new_tuple(null, 0);
        case "LaunchSearch":
            host.launchSearch(childStrv(parameters, 0), childUint(parameters, 1));
            return g_variant_new_tuple(null, 0);
        default:
            return null;
    }
}

/**
 * Introspection data for the interface, as published by GNOME Shell
 */
enum SEARCH_PROVIDER_XML = `<node>
  <interface name="org.gnome.Shell.SearchProvider2">
    <method name="GetInitialResultSet">
      <arg type="as" name="terms" direction="in"/>
      <arg type="as" name="results" direction="out"/>
    </method>
    <method name="GetSubsearchResultSet">
      <arg type="as" name="previous_results" direction="in"/>
      <arg type="as" name="terms" direction="in"/>
      <arg type="as" name="results" direction="out"/>
    </method>
    <method name="GetResultMetas">
      <arg type="as" name="identifiers" direction="in"/>
      <arg type="aa{sv}" name="metas" direction="out"/>
    </method>
    <method name="ActivateResult">
      <arg type="s" name="identifier" direction="in"/>
      <arg type="as" name="terms" direction="in"/>
      <arg type="u" name="timestamp" direction="in"/>
    </method>
    <method name="LaunchSearch">
      <arg type="as" name="terms" direction="in"/>
      <arg type="u" name="timestamp" direction="in"/>
    </method>
  </interface>
</node>`;

private:

__gshared SearchProviderHost _host;
__gshared bool _installed;
__gshared uint registrationId;
__gshared GDBusNodeInfo* nodeInfo;
__gshared GDBusInterfaceVTable vtable;

__gshared extern(C) int function(GApplication*, GDBusConnection*, const(char)*, GError**) parentRegister;
__gshared extern(C) void function(GApplication*, GDBusConnection*, const(char)*) parentUnregister;

extern(C) int onDBusRegister(GApplication* app, GDBusConnection* connection, const(char)* objectPath, GError** err) {
    if (parentRegister !is null && !parentRegister(app, connection, objectPath, err)) return 0;
    // A failure only loses search, Tilix itself should still start
    GError* error;
    if (nodeInfo is null) {
        nodeInfo = g_dbus_node_info_new_for_xml(SEARCH_PROVIDER_XML.ptr, &error);
        if (nodeInfo is null) {
            logError("Could not parse search provider interface", error);
            return 1;
        }
    }
    vtable.methodCall = &onMethodCall;
    GDBusInterfaceInfo* info = g_dbus_node_info_lookup_interface(nodeInfo, SEARCH_PROVIDER_INTERFACE.ptr);
    registrationId = g_dbus_connection_register_object(connection, SEARCH_PROVIDER_PATH.ptr, info, &vtable, null, null, &error);
    if (registrationId == 0) {
        logError("Could not export search provider", error);
    }
    return 1;
}

extern(C) void onDBusUnregister(GApplication* app, GDBusConnection* connection, const(char)* objectPath) {
    if (registrationId > 0) {
        g_dbus_connection_unregister_object(connection, registrationId);
        registrationId = 0;
    }
    if (parentUnregister !is null) parentUnregister(app, connection, objectPath);
}

extern(C) void onMethodCall(GDBusConnection* connection, const(char)* sender, const(char)* objectPath,
        const(char)* interfaceName, const(char)* methodName, GVariant* parameters,
        GDBusMethodInvocation* invocation, void* userData) {
    // Exceptions can't propagate into C, so report them as D-Bus errors
    try {
        GVariant* reply = _host is null ? null : handleSearchMethod(_host, to!string(fromStringz(methodName)), parameters);
        if (reply is null) {
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
        } else {
            g_dbus_method_invocation_return_value(invocation, reply);
        }
    } catch (Exception e) {
        try { warning(e); } catch (Exception) {}
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", toStringz(e.msg));
    }
}

void logError(string message, GError* error) {
    try {
        warningf("%s: %s", message, error is null ? "" : to!string(fromStringz(error.message)));
    } catch (Exception) {}
    if (error !is null) g_error_free(error);
}

string[] childStrv(GVariant* parameters, size_t index) {
    GVariant* child = g_variant_get_child_value(parameters, index);
    scope(exit) g_variant_unref(child);
    size_t length;
    const(char)** values = cast(const(char)**) g_variant_get_strv(child, &length);
    scope(exit) g_free(cast(void*) values);
    string[] result;
    foreach (i; 0 .. length) result ~= to!string(fromStringz(values[i]));
    return result;
}

string childString(GVariant* parameters, size_t index) {
    GVariant* child = g_variant_get_child_value(parameters, index);
    scope(exit) g_variant_unref(child);
    return to!string(fromStringz(g_variant_get_string(child, null)));
}

uint childUint(GVariant* parameters, size_t index) {
    GVariant* child = g_variant_get_child_value(parameters, index);
    scope(exit) g_variant_unref(child);
    return g_variant_get_uint32(child);
}

GVariantType* variantType(string type) {
    // A GVariantType is its type string, the C G_VARIANT_TYPE macro does the same cast
    return cast(GVariantType*) cast(void*) toStringz(type);
}

GVariant* stringVariant(string value) {
    return g_variant_new_string(toStringz(value));
}

GVariant* replyStrv(string[] values) {
    GVariant*[] items = values.map!(v => stringVariant(v)).array;
    GVariant* array = g_variant_new_array(variantType("s"), items.ptr, items.length);
    return g_variant_new_tuple(&array, 1);
}

/**
 * The metas for the requested ids, in the requested order. Ids that are no
 * longer known, i.e. a terminal that was closed, are left out.
 */
GVariant* replyMetas(SearchItem[] items, string[] ids) {
    SearchItem[string] byId;
    foreach (item; items) byId[item.id] = item;

    GVariant*[] metas;
    foreach (id; ids) {
        SearchItem* item = id in byId;
        if (item is null) continue;
        GVariant*[] entries;
        void add(string key, string value) {
            entries ~= g_variant_new_dict_entry(stringVariant(key), g_variant_new_variant(stringVariant(value)));
        }
        add("id", item.id);
        add("name", item.name);
        if (item.description.length > 0) add("description", item.description);
        if (item.icon.length > 0) add("gicon", item.icon);
        metas ~= g_variant_new_array(variantType("{sv}"), entries.ptr, entries.length);
    }
    GVariant* array = g_variant_new_array(variantType("a{sv}"), metas.ptr, metas.length);
    return g_variant_new_tuple(&array, 1);
}

unittest {
    // All terms must match somewhere, in any case
    assert(matchesTerms(["git"], ["git status", "/home/me/dev"]));
    assert(matchesTerms(["DEV", "Git"], ["git status", "/home/me/dev"]));
    assert(matchesTerms(["tilix"], ["Tilix Notes"]));
    assert(!matchesTerms(["dev", "vim"], ["git status", "/home/me/dev"]));
    // Blank terms are ignored and nothing matches no terms
    assert(matchesTerms(["", " git "], ["git"]));
    assert(!matchesTerms([], ["git"]));
    assert(!matchesTerms(["  "], ["git"]));
    assert(!matchesTerms(["git"], []));
}

unittest {
    SearchItem[] items = [
        SearchItem("terminal:1", "vim notes.txt", "", "", ["vim notes.txt", "/home/me/docs"]),
        SearchItem("bookmark:2", "Docs", "", "", ["Docs", "/home/me/docs"]),
        SearchItem("session:/s/dev.json", "dev", "", "", ["dev", "/s/dev.json"]),
    ];
    assert(matchingIds(items, ["docs"]) == ["terminal:1", "bookmark:2"]);
    assert(matchingIds(items, ["dev"]) == ["session:/s/dev.json"]);
    assert(matchingIds(items, ["docs", "vim"]) == ["terminal:1"]);
    assert(matchingIds(items, ["nothing"]).length == 0);
}

unittest {
    ResultKind kind;
    string key;
    foreach (k; [ResultKind.TERMINAL, ResultKind.BOOKMARK, ResultKind.SESSION]) {
        assert(parseResultId(resultId(k, "abc"), kind, key));
        assert(kind == k && key == "abc");
    }
    // Session keys are paths and can contain the separator
    assert(parseResultId(resultId(ResultKind.SESSION, "/a:b/c.json"), kind, key));
    assert(kind == ResultKind.SESSION && key == "/a:b/c.json");
    assert(!parseResultId("terminal:", kind, key));
    assert(!parseResultId("window:1", kind, key));
    assert(!parseResultId("", kind, key));
}

unittest {
    assert(tildePath("/home/me", "/home/me") == "~");
    assert(tildePath("/home/me/src/tilix", "/home/me") == "~/src/tilix");
    assert(tildePath("/home/me/src", "/home/me/") == "~/src");
    // Only whole folder names
    assert(tildePath("/home/meg/src", "/home/me") == "/home/meg/src");
    assert(tildePath("/etc", "/home/me") == "/etc");
    assert(tildePath("/etc", "") == "/etc");
    assert(tildePath("/etc", "/") == "/etc");
}

unittest {
    assert(stripMarkup("plain") == "plain");
    assert(stripMarkup("<b>bold</b> and <span foreground='red'>red</span>") == "bold and red");
    assert(stripMarkup("a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;") == "a & b <c> \"d\" 'e'");
    assert(stripMarkup("&#65;&#x42;") == "AB");
    // Text that isn't valid markup is kept
    assert(stripMarkup("a & b") == "a & b");
    assert(stripMarkup("&unknown; x") == "&unknown; x");
    assert(stripMarkup("1 < 2") == "1 < 2");
}

// The method handler, with the reply types checked against the interface
unittest {
    class FakeHost: SearchProviderHost {
        string activated;
        uint timestamp;
        string[] launched;
        SearchItem[] searchItems() {
            return [
                SearchItem("terminal:1", "htop", "~/src", "com.gexperts.Tilix", ["htop", "/home/me/src"]),
                SearchItem("bookmark:2", "Server", "", "network-server", ["Server", "me@host"]),
            ];
        }
        void activateResult(string id, uint timestamp) {
            activated = id;
            this.timestamp = timestamp;
        }
        void launchSearch(string[] terms, uint timestamp) {
            launched = terms;
            this.timestamp = timestamp;
        }
    }

    GVariant* strv(string[] values) {
        char*[] c = values.map!(v => cast(char*) toStringz(v)).array;
        return g_variant_new_strv(c.ptr, c.length);
    }

    GVariant* tuple(GVariant*[] values...) {
        return g_variant_ref_sink(g_variant_new_tuple(values.ptr, values.length));
    }

    GError* error;
    GDBusNodeInfo* node = g_dbus_node_info_new_for_xml(SEARCH_PROVIDER_XML.ptr, &error);
    assert(node !is null);
    scope(exit) g_dbus_node_info_unref(node);
    GDBusInterfaceInfo* info = g_dbus_node_info_lookup_interface(node, SEARCH_PROVIDER_INTERFACE.ptr);
    assert(info !is null);

    // Calls the method and checks the reply has the type the interface declares
    FakeHost host = new FakeHost();
    GVariant* call(string method, GVariant* params) {
        GDBusMethodInfo* mi = g_dbus_interface_info_lookup_method(info, toStringz(method));
        assert(mi !is null, method);
        string expected = "(";
        for (GDBusArgInfo** arg = mi.outArgs; arg !is null && *arg !is null; arg++) {
            expected ~= to!string(fromStringz((*arg).signature));
        }
        expected ~= ")";
        GVariant* reply = g_variant_ref_sink(handleSearchMethod(host, method, params));
        assert(to!string(fromStringz(g_variant_get_type_string(reply))) == expected, method);
        return reply;
    }

    GVariant* reply = call("GetInitialResultSet", tuple(strv(["SRC"])));
    assert(childStrv(reply, 0) == ["terminal:1"]);
    reply = call("GetSubsearchResultSet", tuple(strv(["terminal:1", "bookmark:2"]), strv(["host"])));
    assert(childStrv(reply, 0) == ["bookmark:2"]);

    // Metas follow the requested order and skip unknown ids
    reply = call("GetResultMetas", tuple(strv(["bookmark:2", "terminal:9", "terminal:1"])));
    GVariant* metas = g_variant_get_child_value(reply, 0);
    assert(g_variant_n_children(metas) == 2);
    string lookup(size_t index, string key) {
        GVariant* dict = g_variant_get_child_value(metas, index);
        GVariant* value = g_variant_lookup_value(dict, toStringz(key), variantType("s"));
        // Tells a missing key apart from an empty value
        if (value is null) return "<missing>";
        return to!string(fromStringz(g_variant_get_string(value, null)));
    }
    assert(lookup(0, "id") == "bookmark:2" && lookup(0, "name") == "Server" && lookup(0, "gicon") == "network-server");
    assert(lookup(0, "description") == "<missing>");
    assert(lookup(1, "id") == "terminal:1" && lookup(1, "description") == "~/src");

    call("ActivateResult", tuple(stringVariant("bookmark:2"), strv(["host"]), g_variant_new_uint32(42)));
    assert(host.activated == "bookmark:2" && host.timestamp == 42);
    call("LaunchSearch", tuple(strv(["a", "b"]), g_variant_new_uint32(7)));
    assert(host.launched == ["a", "b"] && host.timestamp == 7);

    assert(handleSearchMethod(host, "Nope", tuple()) is null);
}
