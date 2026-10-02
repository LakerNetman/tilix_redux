// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
// distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Cinnamon menu search provider for Tilix. It asks a running Tilix over the same
// org.gnome.Shell.SearchProvider2 D-Bus interface GNOME Shell uses, so the searching
// and opening of results is all done by Tilix (see source/gx/tilix/searchprovider.d).
//
// Tilix isn't started for a search: menu searches run on every key press, so with
// Tilix closed this provider just has no results.

const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const St = imports.gi.St;

const BUS_NAME = 'com.gexperts.Tilix';
const OBJECT_PATH = '/com/gexperts/Tilix/SearchProvider';
const INTERFACE = 'org.gnome.Shell.SearchProvider2';
const TIMEOUT_MS = 2000;
const MAX_RESULTS = 10;
const ICON_SIZE = 22;

// The menu shows results whenever they're sent, so replies to an older search are
// dropped rather than added under what the user has typed since
var latestSearch = 0;
var latestTerms = [];

function callTilix(method, parameters, replyType, callback) {
    Gio.DBus.session.call(BUS_NAME, OBJECT_PATH, INTERFACE, method, parameters,
        replyType ? new GLib.VariantType(replyType) : null,
        Gio.DBusCallFlags.NO_AUTO_START, TIMEOUT_MS, null,
        (connection, result) => {
            let reply = null;
            try {
                reply = connection.call_finish(result);
            } catch (e) {
                // Tilix isn't running, or is too old to have a search provider
            }
            if (callback) callback(reply);
        });
}

function makeIcon(iconName) {
    if (!iconName) return null;
    try {
        return new St.Icon({gicon: Gio.icon_new_for_string(iconName), icon_size: ICON_SIZE});
    } catch (e) {
        return null;
    }
}

function perform_search(pattern) {
    let search = ++latestSearch;
    let terms = pattern.split(/\s+/).filter(term => term.length > 0);
    latestTerms = terms;
    if (terms.length === 0) return;

    callTilix('GetInitialResultSet', new GLib.Variant('(as)', [terms]), '(as)', reply => {
        if (search !== latestSearch || reply === null) return;
        let ids = reply.deepUnpack()[0].slice(0, MAX_RESULTS);
        if (ids.length === 0) return;
        callTilix('GetResultMetas', new GLib.Variant('(as)', [ids]), '(aa{sv})', reply => {
            if (search !== latestSearch || reply === null) return;
            let results = reply.recursiveUnpack()[0].map(meta => ({
                id: meta.id,
                label: meta.name,
                description: meta.description || '',
                icon: makeIcon(meta.gicon),
            }));
            if (results.length > 0) send_results(results);
        });
    });
}

function on_result_selected(result) {
    let timestamp = 0;
    try {
        timestamp = global.get_current_time();
    } catch (e) {
        // Only available while handling an event
    }
    callTilix('ActivateResult', new GLib.Variant('(sasu)', [result.id, latestTerms, timestamp]), null, null);
}
