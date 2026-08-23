import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const UI_REFRESH_MS = 1000;

function todayKey() {
    return GLib.DateTime.new_now_local().format('%F');
}

function formatCompact(n) {
    if (n >= 1_000_000)
        return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1000)
        return `${(n / 1000).toFixed(1)}k`;
    return String(n);
}

function emptyDay() {
    return {keys: 0, spaces: 0, chords: 0, mods: 0, peakWpm: 0};
}

function normalizeDay(v) {
    return {
        keys: Number(v?.keys) || 0,
        spaces: Number(v?.spaces) || 0,
        chords: Number(v?.chords) || 0,
        mods: Number(v?.mods) || 0,
        peakWpm: Number(v?.peak_wpm) || 0,
    };
}

function dateMinusDays(isoDate, days) {
    try {
        const [y, m, d] = isoDate.split('-').map(Number);
        const dt = GLib.DateTime.new_local(y, m, d, 12, 0, 0.0);
        if (dt) {
            const prev = dt.add_days(-days);
            if (prev)
                return prev.format('%F');
        }
    } catch (_e) {
        // fall through
    }
    const t = new Date(Number(isoDate.slice(0, 4)), Number(isoDate.slice(5, 7)) - 1,
        Number(isoDate.slice(8, 10)), 12, 0, 0);
    t.setDate(t.getDate() - days);
    const yyyy = t.getFullYear();
    const mm = String(t.getMonth() + 1).padStart(2, '0');
    const dd = String(t.getDate()).padStart(2, '0');
    return `${yyyy}-${mm}-${dd}`;
}

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(extension) {
        super._init(0.5, 'Key Count');
        this._extension = extension;
        this._historyItems = [];

        this._label = new St.Label({
            text: '…',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'keycount-label',
        });
        this.add_child(this._label);

        this._todayKeys = new PopupMenu.PopupMenuItem('Today keys: —', {reactive: false});
        this._todayKeys.label.add_style_class_name('keycount-menu-title');
        this.menu.addMenuItem(this._todayKeys);

        this._todaySpaces = new PopupMenu.PopupMenuItem('Spaces / ~words: —', {reactive: false});
        this.menu.addMenuItem(this._todaySpaces);

        this._todayChords = new PopupMenu.PopupMenuItem('Chords (ctrl/alt/super+…): —', {reactive: false});
        this.menu.addMenuItem(this._todayChords);

        this._todayMods = new PopupMenu.PopupMenuItem('Bare modifiers: —', {reactive: false});
        this.menu.addMenuItem(this._todayMods);

        this._todayPeak = new PopupMenu.PopupMenuItem('Peak WPM (burst): —', {reactive: false});
        this.menu.addMenuItem(this._todayPeak);

        this._sourceItem = new PopupMenu.PopupMenuItem('Source: keycount-daemon (evdev)', {reactive: false});
        this.menu.addMenuItem(this._sourceItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._weekHeader = new PopupMenu.PopupMenuItem('Last 7 days', {reactive: false});
        this._weekHeader.label.add_style_class_name('keycount-menu-title');
        this.menu.addMenuItem(this._weekHeader);

        this._weekTotalItem = new PopupMenu.PopupMenuItem('Week total: —', {reactive: false});
        this.menu.addMenuItem(this._weekTotalItem);
        this._historyAnchor = this._weekTotalItem;

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const openDir = new PopupMenu.PopupMenuItem('Open data folder');
        openDir.connect('activate', () => this._extension.openDataDir());
        this.menu.addMenuItem(openDir);

        this.menu.connect('open-state-changed', (_menu, open) => {
            if (open)
                this._extension.refreshMenu();
        });
    }

    setPanelText(text) {
        this._label.text = text;
    }

    setToday({keys, spaces, chords, mods, peakWpm}) {
        this._todayKeys.label.text = `Today keys: ${keys.toLocaleString()}`;
        this._todaySpaces.label.text = `Spaces / ~words: ${spaces.toLocaleString()}`;
        this._todayChords.label.text = `Chords (ctrl/alt/super+…): ${chords.toLocaleString()}`;
        this._todayMods.label.text = `Bare modifiers: ${mods.toLocaleString()}`;
        this._todayPeak.label.text = `Peak WPM (burst): ${Math.round(peakWpm)}`;
    }

    setSource(text) {
        this._sourceItem.label.text = `Source: ${text}`;
    }

    setWeek(rows, totals) {
        this._weekTotalItem.label.text =
            `Week total: ${totals.keys.toLocaleString()} keys · ` +
            `${totals.spaces.toLocaleString()}w · ${totals.chords.toLocaleString()} chords · ` +
            `peak ${Math.round(totals.peakWpm)} wpm`;

        for (const item of this._historyItems)
            item.destroy();
        this._historyItems = [];

        let insertAt = this.menu._getMenuItems().indexOf(this._historyAnchor) + 1;
        if (insertAt < 1)
            insertAt = -1;

        for (const row of rows) {
            const mark = row.isToday ? ' (today)' : '';
            const label =
                `${row.date}${mark}  ·  ${row.keys.toLocaleString()} keys` +
                `  ·  ${row.spaces.toLocaleString()}w` +
                `  ·  ${row.chords.toLocaleString()} chords` +
                `  ·  ${Math.round(row.peakWpm)} wpm`;
            const item = new PopupMenu.PopupMenuItem(label, {reactive: false});
            this.menu.addMenuItem(item, insertAt);
            if (insertAt >= 0)
                insertAt += 1;
            this._historyItems.push(item);
        }
    }
});

export default class KeyCountExtension extends Extension {
    enable() {
        this._stats = {};
        this._day = todayKey();
        this._uiTimeoutId = 0;

        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);

        this._uiTimeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, UI_REFRESH_MS, () => {
            this._day = todayKey();
            this._load();
            this._updatePanel();
            return GLib.SOURCE_CONTINUE;
        });

        this._load();
        this._updatePanel();
        this.refreshMenu();
    }

    disable() {
        if (this._uiTimeoutId) {
            GLib.source_remove(this._uiTimeoutId);
            this._uiTimeoutId = 0;
        }
        this._indicator?.destroy();
        this._indicator = null;
        this._stats = null;
    }

    _dataDirPath() {
        return GLib.build_filenamev([GLib.get_user_data_dir(), 'keycount']);
    }

    _statsPath() {
        return GLib.build_filenamev([this._dataDirPath(), 'stats.json']);
    }

    _load() {
        const file = Gio.File.new_for_path(this._statsPath());
        if (!file.query_exists(null)) {
            this._stats = {};
            return;
        }
        try {
            const [, bytes] = file.load_contents(null);
            const text = new TextDecoder().decode(bytes);
            const parsed = JSON.parse(text);
            if (!parsed || typeof parsed !== 'object') {
                this._stats = {};
                return;
            }
            const out = {};
            for (const [date, day] of Object.entries(parsed)) {
                if (/^\d{4}-\d{2}-\d{2}$/.test(date))
                    out[date] = normalizeDay(day);
            }
            this._stats = out;
        } catch (_e) {
            this._stats = {};
        }
    }

    _today() {
        return normalizeDay(this._stats?.[this._day]);
    }

    _weekRows() {
        const rows = [];
        const totals = emptyDay();
        for (let i = 0; i < 7; i++) {
            const date = dateMinusDays(this._day, i);
            const day = normalizeDay(this._stats?.[date]);
            rows.push({date, isToday: i === 0, ...day});
            totals.keys += day.keys;
            totals.spaces += day.spaces;
            totals.chords += day.chords;
            totals.mods += day.mods;
            totals.peakWpm = Math.max(totals.peakWpm, day.peakWpm);
        }
        return {rows, totals};
    }

    _updatePanel() {
        if (!this._indicator)
            return;
        const day = this._today();
        this._indicator.setPanelText(`${formatCompact(day.keys)} · ${formatCompact(day.spaces)}w`);
        this._indicator.setToday(day);
    }

    refreshMenu() {
        if (!this._indicator)
            return;
        this._load();
        const day = this._today();
        this._indicator.setToday(day);
        const {rows, totals} = this._weekRows();
        this._indicator.setWeek(rows, totals);

        const path = this._statsPath();
        const file = Gio.File.new_for_path(path);
        this._indicator.setSource(
            file.query_exists(null)
                ? 'keycount-daemon (evdev)'
                : 'waiting for keycount-daemon…'
        );
    }

    openDataDir() {
        const path = this._dataDirPath();
        try {
            Gio.File.new_for_path(path).make_directory_with_parents(null);
        } catch (_e) {
            // ignore
        }
        try {
            Gio.AppInfo.launch_default_for_uri(`file://${path}`, null);
        } catch (_e) {
            // ignore
        }
    }
}
