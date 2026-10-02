// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
// distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Runs the Cinnamon search provider (data/cinnamon/tilix@gexperts.com/search_provider.js) in cjs,
// outside Cinnamon, against the probe of search-provider-dbus.sh on a private bus. St and global
// only exist inside Cinnamon, so they're replaced with fakes; Gio, GLib and D-Bus are real.
//
// Usage: cjs cinnamon-search-harness.js PLUGIN_FILE PROBE_LOG   (run by search-provider-dbus.sh)

const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const ByteArray = imports.byteArray;

const [pluginFile, probeLog] = ARGV;
const BUS_NAME = 'com.gexperts.Tilix';

let failures = 0;
function check(label, ok) {
    print(`  ${ok ? 'ok  ' : 'FAIL'} ${label}`);
    if (!ok) failures++;
}

// Fakes for what Cinnamon provides
const FakeSt = {
    Icon: class {
        constructor(params) {
            this.iconName = params.gicon.to_string();
            this.size = params.icon_size;
        }
    },
};
let currentTime = 0;
const fakeGlobal = {get_current_time: () => currentTime};
let sent = [];
const sendResults = results => sent.push(results);

// Loads the plugin as Cinnamon would, a module whose send_results Cinnamon sets
const source = ByteArray.toString(GLib.file_get_contents(pluginFile)[1]);
const fakeImports = {gi: {Gio: Gio, GLib: GLib, St: FakeSt}};
const plugin = new Function('imports', 'global', 'send_results',
    source + '\nreturn {perform_search, on_result_selected};')(fakeImports, fakeGlobal, sendResults);

// Runs the main loop so D-Bus replies arrive
function wait(ms) {
    const loop = new GLib.MainLoop(null, false);
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => { loop.quit(); return GLib.SOURCE_REMOVE; });
    loop.run();
}

function busCall(method, params, type) {
    return Gio.DBus.session.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
        method, params, new GLib.VariantType(type), Gio.DBusCallFlags.NONE, 5000, null).deepUnpack()[0];
}
const tilixRunning = () => busCall('NameHasOwner', new GLib.Variant('(s)', [BUS_NAME]), '(b)');

function readLog() {
    try {
        return ByteArray.toString(GLib.file_get_contents(probeLog)[1]);
    } catch (e) {
        return '';
    }
}

// 1. Tilix isn't running: no results, and a search must not start it
plugin.perform_search('docs');
wait(1000);
check('no results while Tilix is not running', sent.length === 0);
check('a search does not start Tilix', !tilixRunning());

// Start the probe, as if Tilix was opened
busCall('StartServiceByName', new GLib.Variant('(su)', [BUS_NAME, 0]), '(u)');
check('probe started for the remaining checks', tilixRunning());

// 2. A search returns the metas, with an icon from the gicon string
sent = [];
plugin.perform_search('docs');
wait(500);
check('one batch of results sent', sent.length === 1);
const first = (sent[0] || [])[0] || {};
check('result has the id, name and description',
    sent.length === 1 && sent[0].length === 1 && first.id === 'terminal:t1' && first.label === 'vim notes' &&
    first.description === 'Default — ~/docs');
check('result icon comes from the gicon', first.icon && first.icon.iconName === 'com.gexperts.Tilix');

// 3. Several words are separate terms, matching across fields
sent = [];
plugin.perform_search('me@host  server');
wait(500);
check('multiple words are separate terms', sent.length === 1 && sent[0].length === 1 && sent[0][0].id === 'bookmark:b1');

// 4. A reply to an older search is dropped
sent = [];
plugin.perform_search('docs');
plugin.perform_search('host');
wait(500);
check('only the latest search sends results',
    sent.length === 1 && sent[0].length === 1 && sent[0][0].id === 'bookmark:b1');

// 5. No match sends nothing, and an empty search doesn't even ask Tilix
const itemCalls = () => (readLog().match(/^items$/gm) || []).length;
sent = [];
plugin.perform_search('zzz');
wait(500);
check('no match sends nothing', sent.length === 0);
const before = itemCalls();
plugin.perform_search('   ');
wait(500);
check('an empty search does not call Tilix', sent.length === 0 && itemCalls() === before && before > 0);

// 6. Picking a result asks Tilix to open it, with the event time
currentTime = 4242;
plugin.on_result_selected({id: 'bookmark:b1'});
wait(500);
check('picking a result activates it with the timestamp', readLog().includes('activate bookmark:b1 4242'));

print(`cinnamon failures: ${failures}`);
