/* ══════════════════════════════════════════════════════════════════════
   77-codedoors — interface logic
   ══════════════════════════════════════════════════════════════════════ */

/* ══════════════════════════════════════════════════════════════════════
   The resource folder name is NOT always "77-codedoors" (this build is
   delivered as "codelock"), and NUI callbacks must be sent to
   https://<folder name>/<callback>. Resolving it at runtime is what keeps
   close / save / code entry working no matter how the folder is named.

   1. GetParentResourceName() is provided by the game's browser,
   2. otherwise the client pushes its name in the "init" message,
   3. anything sent before we know the name is queued and flushed.
   ══════════════════════════════════════════════════════════════════════ */

let resourceName = (typeof window.GetParentResourceName === 'function'
    && window.GetParentResourceName()) || null;

let postQueue = [];
let readySent = false;

/* callbacks that are safe to retry (they never change anything twice) */
const RETRYABLE = ['close', 'ready', 'heartbeat', 'adminRefresh'];

const $ = (id) => document.getElementById(id);

function post(name, data = {}, retries = 1) {
    if (!resourceName) {
        if (name !== 'heartbeat') postQueue.push([name, data]);
        return Promise.resolve();
    }

    return fetch(`https://${resourceName}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
    }).catch(() => {
        if (retries > 0 && RETRYABLE.includes(name)) {
            return new Promise((resolve) => setTimeout(resolve, 400))
                .then(() => post(name, data, retries - 1));
        }
        return null;
    });
}

function flushPostQueue() {
    const queued = postQueue;
    postQueue = [];
    queued.forEach(([name, data]) => post(name, data));
}

function sendReady() {
    if (readySent) return;
    readySent = true;
    post('ready');
}

const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
));

const TYPE_LABEL = {
    door: 'Single door',
    double: 'Double door',
    gate: 'Gate',
    garage: 'Garage door',
};

const ICON = {
    door: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="6" y="3" width="12" height="18" rx="1.4"/><circle cx="14.6" cy="12" r="1" fill="currentColor" stroke="none"/></svg>',
    double: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="3" y="3" width="8" height="18" rx="1.2"/><rect x="13" y="3" width="8" height="18" rx="1.2"/></svg>',
    gate: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M4 21V8M9 21V8M14 21V8M19 21V8M3 8h18" stroke-linecap="round"/></svg>',
    garage: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="4" y="4" width="16" height="16" rx="1.5"/><path d="M4 9h16M4 13.5h16M4 18h16" stroke-linecap="round"/></svg>',
};

const I_EYE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M2.5 12S6 6 12 6s9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6z"/><circle cx="12" cy="12" r="2.6"/></svg>';
const I_EYE_OFF = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M4 4l16 16" stroke-linecap="round"/><path d="M9.6 5.6A9.9 9.9 0 0 1 12 5.3c6 0 9.5 6.2 9.5 6.2a17 17 0 0 1-3.4 4M6.3 8A16.6 16.6 0 0 0 2.5 11.5S6 17.7 12 17.7a9.7 9.7 0 0 0 3.2-.5"/></svg>';
const I_PIN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M12 21s7-6.2 7-11a7 7 0 1 0-14 0c0 4.8 7 11 7 11z"/><circle cx="12" cy="10" r="2.5"/></svg>';
const I_EDIT = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M4 20h4L18 10l-4-4L4 16v4z" stroke-linejoin="round"/></svg>';
const I_TRASH = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M4 7h16M9 7V4.8h6V7M6.5 7l1 13h9l1-13" stroke-linecap="round" stroke-linejoin="round"/></svg>';

const app = $('app');
const panelEl = $('panel');
const keypadEl = $('keypad');
const rowsEl = $('rows');
const leavesEl = $('f-leaves');
const dotsEl = $('kp-dots');

const state = {
    doors: [],
    meta: {},
    view: 'list',
    filter: 'all',
    search: '',
    revealed: new Set(),
    confirmDelete: null,
    form: null,
    keypad: null,
};

let stash = null;          // form values kept while the creator is running
let lastResultTimer = null;

/* ═══════════════════════════ helpers ═══════════════════════════ */

function pinLength() {
    return Math.max(3, Math.min(8, Number(state.meta.pinLength) || 4));
}

function toast(kind, message) {
    const el = document.createElement('div');
    el.className = `toast ${kind || 'info'}`;
    el.textContent = message;
    $('toasts').appendChild(el);
    setTimeout(() => {
        el.classList.add('leaving');
        setTimeout(() => el.remove(), 220);
    }, 4200);
}

function closeAll() {
    app.classList.add('hidden');
    panelEl.classList.add('hidden');
    keypadEl.classList.add('hidden');
}

function doorById(id) {
    return state.doors.find((d) => d.id === id) || null;
}

/* ═══════════════════════════ admin panel ═══════════════════════════ */

function setView(view) {
    // 'create' and 'edit' share the same view container
    state.view = (view === 'create' || view === 'edit') ? 'form' : view;

    $('view-list').classList.toggle('hidden', state.view !== 'list');
    $('view-form').classList.toggle('hidden', state.view !== 'form');
    $('view-help').classList.toggle('hidden', state.view !== 'help');

    document.querySelectorAll('.nav-item').forEach((btn) => {
        const target = btn.dataset.view;
        const active = target === state.view || (state.view === 'form' && target === 'create');
        btn.classList.toggle('is-active', active);
    });
}

function renderStats() {
    const locked = state.doors.filter((d) => d.locked).length;
    $('stat-total').textContent = state.doors.length;
    $('stat-locked').textContent = locked;
    $('stat-open').textContent = state.doors.length - locked;
}

function visibleDoors() {
    const query = state.search.trim().toLowerCase();

    return state.doors.filter((door) => {
        if (state.filter === 'locked' && !door.locked) return false;
        if (state.filter === 'unlocked' && door.locked) return false;
        if (!query) return true;

        return (door.name || '').toLowerCase().includes(query)
            || (door.zone || '').toLowerCase().includes(query)
            || String(door.pin || '').includes(query)
            || (door.doors || []).some((leaf) => String(leaf.name || '').toLowerCase().includes(query));
    });
}

function rowHtml(door, index) {
    const type = TYPE_LABEL[door.type] ? door.type : 'door';
    const leaves = door.doors || [];
    const leafCount = leaves.length;
    const shown = state.revealed.has(door.id) ? esc(door.pin) : '•'.repeat(String(door.pin || '••••').length);
    const confirming = state.confirmDelete === door.id;

    return `
    <div class="row" data-id="${esc(door.id)}" style="animation-delay:${Math.min(index * 16, 190)}ms">
        <div class="type-icon t-${type}">${ICON[type]}</div>

        <div class="row-name">
            <strong>${esc(door.name)}</strong>
            <div class="row-meta">
                <span class="zone">${esc(door.zone || 'Unknown area')}</span>
                <span class="sep">•</span>
                <span class="tag">${TYPE_LABEL[type]}</span>
                <span class="sep">•</span>
                <span>${leafCount} door${leafCount > 1 ? 's' : ''}</span>
                <span class="sep">•</span>
                <span>auto ${door.autoClose || 0}s</span>
            </div>
        </div>

        <div class="pin-cell">
            <code>${shown}</code>
            <button class="eye" data-reveal="${esc(door.id)}" title="Show / hide the code">
                ${state.revealed.has(door.id) ? I_EYE_OFF : I_EYE}
            </button>
        </div>

        <button class="state-toggle ${door.locked ? 'is-locked' : 'is-open'}" data-toggle="${esc(door.id)}">
            <span class="dot"></span>${door.locked ? 'Locked' : 'Unlocked'}
        </button>

        <div class="row-actions">
            <button class="icon-btn" data-teleport="${esc(door.id)}" title="Go to this door">${I_PIN}</button>
            <button class="icon-btn" data-edit="${esc(door.id)}" title="Edit">${I_EDIT}</button>
            <button class="icon-btn danger ${confirming ? 'confirm' : ''}" data-delete="${esc(door.id)}" title="Delete">
                ${confirming ? 'Sure?' : I_TRASH}
            </button>
        </div>
    </div>`;
}

function renderRows() {
    const list = visibleDoors();

    rowsEl.innerHTML = list.map(rowHtml).join('');
    $('empty').classList.toggle('hidden', list.length > 0);
    renderStats();
}

function findFirstLeaf(door) {
    const leaf = (door.doors || [])[0];
    return leaf && leaf.coords ? leaf : null;
}

rowsEl.addEventListener('click', (event) => {
    const reveal = event.target.closest('[data-reveal]');
    const toggle = event.target.closest('[data-toggle]');
    const edit = event.target.closest('[data-edit]');
    const remove = event.target.closest('[data-delete]');
    const teleport = event.target.closest('[data-teleport]');

    if (reveal) {
        const id = reveal.dataset.reveal;
        state.revealed.has(id) ? state.revealed.delete(id) : state.revealed.add(id);
        renderRows();
        return;
    }

    if (toggle) {
        const door = doorById(toggle.dataset.toggle);
        if (door) post('adminSetLock', { id: door.id, locked: !door.locked });
        return;
    }

    if (teleport) {
        const door = doorById(teleport.dataset.teleport);
        const leaf = door && findFirstLeaf(door);
        if (leaf) post('adminTeleport', { coords: leaf.coords, heading: leaf.heading });
        return;
    }

    if (edit) {
        const door = doorById(edit.dataset.edit);
        if (door) openForm('edit', null, door);
        return;
    }

    if (remove) {
        const id = remove.dataset.delete;
        if (state.confirmDelete === id) {
            state.confirmDelete = null;
            post('adminDelete', { id });
        } else {
            state.confirmDelete = id;
            renderRows();
            setTimeout(() => {
                if (state.confirmDelete === id) {
                    state.confirmDelete = null;
                    renderRows();
                }
            }, 3500);
        }
    }
});

/* ═══════════════════════════ create / edit form ═══════════════════════════ */

function setPinInputs(value) {
    const inputs = [...$('f-pin').querySelectorAll('input')];
    const digits = String(value || '').split('');
    inputs.forEach((input, i) => { input.value = digits[i] || ''; });
}

function getPinInputs() {
    return [...$('f-pin').querySelectorAll('input')].map((i) => i.value.trim()).join('');
}

function renderLeaves() {
    const leaves = state.form ? state.form.doors : [];
    $('f-leafcount').textContent = `${leaves.length} / 4`;

    if (!leaves.length) {
        leavesEl.innerHTML = '<li class="placeholder">No door captured yet — press “Look at doors”.</li>';
        return;
    }

    leavesEl.innerHTML = leaves.map((leaf, i) => {
        const coords = leaf.coords || {};
        const point = `${Number(coords.x || 0).toFixed(1)}, ${Number(coords.y || 0).toFixed(1)}, ${Number(coords.z || 0).toFixed(1)}`;
        return `
        <li class="leaf">
            <span class="leaf-index">${i + 1}</span>
            <span class="leaf-body">
                <strong>${esc(leaf.name || `model ${leaf.model || '?'}`)}</strong>
                <span>${point}</span>
            </span>
            <button class="icon-btn danger" data-remove-leaf="${i}" title="Remove this door">${I_TRASH}</button>
        </li>`;
    }).join('');
}

leavesEl.addEventListener('click', (event) => {
    const btn = event.target.closest('[data-remove-leaf]');
    if (!btn || !state.form) return;
    state.form.doors.splice(Number(btn.dataset.removeLeaf), 1);
    renderLeaves();
});

function applyTypePreset(type, force) {
    const preset = (state.meta.types || {})[type];
    if (!preset) return;
    $('f-holdopen').checked = !!preset.holdOpen;
    $('f-auto').checked = !!preset.auto;
}

function setFormType(type) {
    if (!TYPE_LABEL[type]) type = 'door';
    if (state.form) state.form.type = type;
    document.querySelectorAll('#f-type button').forEach((btn) => {
        btn.classList.toggle('is-active', btn.dataset.type === type);
    });
}

function readFormValues() {
    if (!state.form) return null;
    return {
        id: state.form.id,
        name: $('f-name').value.trim(),
        type: state.form.type,
        pin: getPinInputs(),
        autoClose: Number($('f-autoclose').value),
        distance: Number($('f-distance').value),
        auto: $('f-auto').checked,
        holdOpen: $('f-holdopen').checked,
        zone: state.form.zone,
        doors: state.form.doors,
    };
}

function openForm(view, draft, existing) {
    const door = existing || (draft && draft.id ? doorById(draft.id) : null);
    const targetId = door ? door.id : ((draft && draft.id) || null);

    // values typed in before a "look at doors" round trip are kept
    let base = (stash && (stash.id || null) === targetId) ? stash : {
        id: targetId,
        name: draft && draft.zone ? draft.zone : (door ? door.name : ''),
        type: door ? door.type : 'door',
        pin: door ? door.pin : '',
        autoClose: door ? door.autoClose : (state.meta.defaults ? state.meta.defaults.autoClose : 30),
        distance: door ? door.distance : (state.meta.defaults ? state.meta.defaults.distance : 2.5),
        auto: door ? door.auto : undefined,
        holdOpen: door ? door.holdOpen : undefined,
        zone: (draft && draft.zone) || (door ? door.zone : '') || '',
        doors: (door ? door.doors : []) || [],
    };

    // a fresh capture always wins over what was there before
    if (draft && Array.isArray(draft.doors) && draft.doors.length) base.doors = draft.doors;

    stash = null;
    state.form = base;

    $('form-title').textContent = door ? `Edit — ${door.name}` : 'New door lock';
    $('form-sub').textContent = door
        ? 'Re-capture the doors or change any setting, then save.'
        : 'Captured doors are listed on the right.';

    $('f-name').value = base.name || '';
    setPinInputs(base.pin || '');
    $('f-autoclose').value = base.autoClose || 30;
    $('f-distance').value = base.distance || 2.5;
    $('f-autoclose-val').textContent = `${base.autoClose || 30} s`;
    $('f-distance-val').textContent = `${Number(base.distance || 2.5).toFixed(1)} m`;

    $('f-pin').querySelectorAll('input').forEach((input) => {
        input.maxLength = 1;
    });

    setFormType(base.type || 'door');
    if (base.auto === undefined || base.holdOpen === undefined) {
        applyTypePreset(base.type || 'door');
    } else {
        $('f-auto').checked = !!base.auto;
        $('f-holdopen').checked = !!base.holdOpen;
    }

    renderLeaves();
    setView(door ? 'edit' : 'create');
}

$('f-type').addEventListener('click', (event) => {
    const btn = event.target.closest('button[data-type]');
    if (!btn) return;
    setFormType(btn.dataset.type);
    applyTypePreset(btn.dataset.type);
});

$('f-autoclose').addEventListener('input', (e) => {
    $('f-autoclose-val').textContent = `${e.target.value} s`;
});

$('f-distance').addEventListener('input', (e) => {
    $('f-distance-val').textContent = `${Number(e.target.value).toFixed(1)} m`;
});

$('f-pin').addEventListener('input', (event) => {
    const input = event.target;
    input.value = input.value.replace(/\D/g, '').slice(0, 1);
    if (input.value) {
        const inputs = [...$('f-pin').querySelectorAll('input')];
        const next = inputs[inputs.indexOf(input) + 1];
        if (next) next.focus();
    }
});

$('f-pin').addEventListener('keydown', (event) => {
    if (event.key !== 'Backspace') return;
    const input = event.target;
    if (input.value) return;
    const inputs = [...$('f-pin').querySelectorAll('input')];
    const prev = inputs[inputs.indexOf(input) - 1];
    if (prev) {
        prev.focus();
        prev.value = '';
        event.preventDefault();
    }
});

$('f-capture').addEventListener('click', () => {
    stash = readFormValues();
    post('adminStartCapture', { id: stash ? stash.id : null, doors: stash ? stash.doors : [] });
});

$('form-save').addEventListener('click', () => {
    const values = readFormValues();
    if (!values) return;

    if (!values.name) return toast('error', 'Give the lock a name first');
    if (!new RegExp(`^\\d{${pinLength()}}$`).test(values.pin)) {
        return toast('error', `The code has to be ${pinLength()} digits`);
    }
    if (!values.doors.length) {
        return toast('error', 'No door selected — look at a door and press E');
    }

    post('adminSave', values);
    toast('info', 'Saving lock…');
    openFormReset();
    setView('list');
});

function openFormReset() {
    state.form = null;
    stash = null;
}

$('form-cancel').addEventListener('click', () => {
    openFormReset();
    setView('list');
    renderRows();
});

$('btn-new').addEventListener('click', () => post('adminNewDoor'));

$('btn-close').addEventListener('click', () => {
    closeAll();
    post('close');
});

$('search').addEventListener('input', (event) => {
    state.search = event.target.value;
    renderRows();
});

$('filters').addEventListener('click', (event) => {
    const chip = event.target.closest('.chip');
    if (!chip) return;
    state.filter = chip.dataset.filter;
    document.querySelectorAll('#filters .chip').forEach((c) => c.classList.toggle('is-active', c === chip));
    renderRows();
});

document.querySelectorAll('.nav-item').forEach((btn) => {
    btn.addEventListener('click', () => {
        const view = btn.dataset.view;
        if (view === 'create') {
            openFormReset();
            openForm('create', null, null);
        } else {
            openFormReset();
            setView(view);
            renderRows();
        }
    });
});

/* ═══════════════════════════ keypad ═══════════════════════════ */

function renderKeypad() {
    const kp = state.keypad;
    if (!kp) return;

    const len = pinLength();
    const door = kp.door;

    $('kp-type').textContent = TYPE_LABEL[door.type] || 'Door';
    $('kp-name').textContent = door.name || 'Door';
    $('kp-zone').textContent = door.zone ? door.zone : '';

    const changing = kp.mode === 'change';
    $('kp-steps').classList.toggle('hidden', !changing);

    document.querySelectorAll('.kp-step').forEach((step) => {
        const index = Number(step.dataset.step);
        step.classList.toggle('is-active', index === kp.step);
        step.classList.toggle('is-done', index < kp.step);
    });

    const labels = changing
        ? ['Enter your current code', 'Choose a new code', 'Repeat the new code']
        : ['Enter access code'];
    $('kp-label').textContent = labels[changing ? kp.step : 0];

    dotsEl.classList.remove('is-bad', 'is-ok');
    dotsEl.innerHTML = Array.from({ length: len }, (_, i) =>
        `<span class="${i < kp.entry.length ? 'is-filled' : ''}"></span>`).join('');

    $('kp-submit').textContent = changing
        ? (kp.step < 2 ? 'Continue' : 'Save new code')
        : 'Unlock';

    $('kp-change').classList.toggle('hidden', !kp.config.canChange || changing || !door.locked);
    $('kp-hint').innerHTML = changing
        ? 'Codes are checked on the server &middot; <kbd>Esc</kbd> to cancel'
        : 'Press <kbd>Esc</kbd> to close';
}

function keypadError(message) {
    $('kp-error').textContent = message || 'Wrong code';
    $('kp-error').classList.remove('ok');
    dotsEl.classList.add('is-bad');
    setTimeout(() => dotsEl.classList.remove('is-bad'), 700);
}

function keypadInput(key) {
    const kp = state.keypad;
    if (!kp || kp.busy) return;

    if (key === 'clear') {
        kp.entry = '';
    } else if (key === 'back') {
        kp.entry = kp.entry.slice(0, -1);
    } else if (/^\d$/.test(key)) {
        if (kp.entry.length >= pinLength()) return;
        kp.entry += key;
    } else {
        return;
    }

    $('kp-error').innerHTML = '&nbsp;';
    $('kp-error').classList.remove('ok');
    renderKeypad();

    if (kp.entry.length === pinLength()) {
        setTimeout(() => keypadSubmit(), 190);
    }
}

function keypadSubmit() {
    const kp = state.keypad;
    if (!kp) return;

    // swallow a second submit fired right after a step was completed
    if (!kp.entry.length && performance.now() - (kp.stepAt || 0) < 600) return;

    if (kp.entry.length < pinLength()) {
        keypadError(`Enter all ${pinLength()} digits`);
        return;
    }

    if (kp.mode === 'change') {
        if (kp.step === 0) {
            kp.current = kp.entry;
            kp.step = 1;
            kp.entry = '';
            kp.stepAt = performance.now();
            return renderKeypad();
        }
        if (kp.step === 1) {
            kp.newCode = kp.entry;
            kp.step = 2;
            kp.entry = '';
            kp.stepAt = performance.now();
            return renderKeypad();
        }
        if (kp.entry !== kp.newCode) {
            keypadError('The two codes do not match');
            kp.newCode = null;
            kp.step = 1;
            kp.entry = '';
            kp.stepAt = performance.now();
            return renderKeypad();
        }
    }

    if (kp.busy) return;
    kp.busy = true;

    post('submitCode', {
        id: kp.door.id,
        code: kp.mode === 'change' ? kp.current : kp.entry,
        mode: kp.mode,
        newCode: kp.mode === 'change' ? kp.newCode : undefined,
    });

    // if the server never answers, let the player try again
    const guarded = kp;
    setTimeout(() => {
        if (state.keypad === guarded && guarded.busy) guarded.busy = false;
    }, 3000);
}

$('kp-pad').addEventListener('click', (event) => {
    const btn = event.target.closest('button[data-key]');
    if (btn) keypadInput(btn.dataset.key);
});

$('kp-submit').addEventListener('click', () => keypadSubmit());

$('kp-change').addEventListener('click', () => {
    const kp = state.keypad;
    if (!kp || kp.mode === 'change') return;
    kp.mode = 'change';
    kp.step = 0;
    kp.entry = '';
    kp.stepAt = performance.now();
    kp.current = null;
    kp.newCode = null;
    renderKeypad();
});

/* ═══════════════════════════ messages from Lua ═══════════════════════════ */

window.addEventListener('message', (event) => {
    const data = event.data || {};

    switch (data.action) {
        case 'init': {
            // handshake from the client: carries the real resource name
            if (typeof data.resource === 'string' && data.resource && data.resource !== resourceName) {
                resourceName = data.resource;
                flushPostQueue();
            }
            sendReady();
            break;
        }

        case 'openPanel': {
            state.doors = Array.isArray(data.doors) ? data.doors : [];
            state.meta = data.meta || {};
            app.classList.remove('hidden');
            panelEl.classList.remove('hidden');
            keypadEl.classList.add('hidden');
            renderRows();
            const view = data.view || 'list';
            if (view === 'create') {
                openForm('create', data.draft || null, null);
            } else if (view === 'edit') {
                openForm('edit', data.draft || null, null);
            } else {
                openFormReset();
                setView('list');
            }
            break;
        }

        case 'doors': {
            state.doors = Array.isArray(data.doors) ? data.doors : [];
            renderStats();
            if (state.view === 'list') renderRows();
            break;
        }

        case 'keypad': {
            app.classList.remove('hidden');
            panelEl.classList.add('hidden');
            keypadEl.classList.remove('hidden');
            $('kp-error').innerHTML = '&nbsp;';
            state.keypad = {
                door: data.door || {},
                mode: data.mode === 'change' ? 'change' : 'unlock',
                config: data.config || {},
                step: 0,
                stepAt: 0,
                entry: '',
                current: null,
                newCode: null,
                busy: false,
            };
            renderKeypad();
            break;
        }

        case 'keypadResult': {
            const kp = state.keypad;
            if (!kp) break;
            clearTimeout(lastResultTimer);

            if (data.success) {
                kp.busy = true;
                dotsEl.classList.add('is-ok');
                dotsEl.innerHTML = Array.from({ length: pinLength() }, () => '<span class="is-filled"></span>').join('');
                $('kp-error').textContent = data.message === 'changed' ? 'Code updated' : 'Unlocked';
                $('kp-error').classList.add('ok');
                $('kp-label').textContent = 'Access granted';
                lastResultTimer = setTimeout(() => {
                    state.keypad = null;
                    closeAll();
                    post('close');
                }, 950);
                break;
            }

            kp.busy = false;
            kp.entry = '';
            if (kp.mode === 'change') {
                kp.step = 0;
                kp.current = null;
                kp.newCode = null;
                keypadError(data.message === 'invalid-new' ? 'That code cannot be used' : 'Wrong current code');
            } else {
                keypadError('Wrong code — try again');
            }
            renderKeypad();
            dotsEl.classList.add('is-bad');
            setTimeout(() => dotsEl.classList.remove('is-bad'), 700);
            break;
        }

        case 'toast': {
            toast(data.kind, data.message);
            break;
        }

        case 'close': {
            state.keypad = null;
            state.form = null;
            closeAll();
            break;
        }
    }
});

/* ═══════════════════════════ keyboard ═══════════════════════════ */

document.addEventListener('keydown', (event) => {
    const keypadVisible = !keypadEl.classList.contains('hidden');
    const panelVisible = !panelEl.classList.contains('hidden');

    if (keypadVisible) {
        if (/^[0-9]$/.test(event.key)) keypadInput(event.key);
        else if (event.key === 'Backspace') keypadInput('back');
        else if (event.key === 'Delete') keypadInput('clear');
        else if (event.key === 'Enter') keypadSubmit();
        else if (event.key === 'Escape') {
            state.keypad = null;
            closeAll();
            post('close');
        } else {
            return;
        }
        event.preventDefault();
        return;
    }

    if (panelVisible && event.key === 'Escape') {
        closeAll();
        post('close');
    }
});

/* ═══════════════════════════════════════════════════════════════════
   Optional design preview
   Open html/index.html?preview=panel or ?preview=keypad in a browser
   (with the FiveM client nothing ever carries a query string, so this
   block is always skipped in-game).
   ═══════════════════════════════════════════════════════════════════ */

if (/preview/.test(location.search)) {
    const leaf = (name, x, y, z, heading) => ({
        hash: Math.round(x * 100 + y), model: 12345, name,
        coords: { x, y, z }, heading,
    });

    const demo = [
        { id: 'demo1', name: 'Legion Square Garage', type: 'garage', pin: '4821', locked: true, autoClose: 30, distance: 3, auto: true, holdOpen: true, zone: 'Pillbox Hill', doors: [leaf('prop_garage_door_01', 215.7, -810.2, 30.7, 0)] },
        { id: 'demo2', name: 'MRPD Front Doors', type: 'double', pin: '1120', locked: true, autoClose: 30, distance: 2.5, auto: false, holdOpen: false, zone: 'Mission Row', doors: [leaf('prop_door_01', 434.1, -982.3, 30.7, 90), leaf('prop_door_01', 434.1, -980.3, 30.7, 270)] },
        { id: 'demo3', name: 'Pacific Bank Vault', type: 'door', pin: '7391', locked: false, autoClose: 15, distance: 2, auto: false, holdOpen: false, zone: 'Vinewood Blvd', doors: [leaf('hei_prop_heist_sec_door', 253.1, 224.5, 101.9, 160)] },
        { id: 'demo4', name: 'Grapeseed Farm Gate', type: 'gate', pin: '0007', locked: true, autoClose: 60, distance: 4, auto: true, holdOpen: true, zone: 'Grapeseed', doors: [leaf('prop_gate_farm_03', 2445.2, 4971.4, 46.8, 45)] },
    ];

    const send = (data) => window.dispatchEvent(new MessageEvent('message', { data }));

    if (/keypad/.test(location.search)) {
        send({
            action: 'keypad',
            mode: 'unlock',
            door: { id: 'demo2', name: 'MRPD Front Doors', type: 'double', locked: true, zone: 'Mission Row' },
            config: { pinLength: 4, canChange: true },
        });
    } else {
        send({
            action: 'openPanel',
            view: 'list',
            doors: demo,
            meta: {
                total: demo.length,
                locked: 3,
                types: { door: { label: 'Single Door' }, double: { label: 'Double Door' }, gate: { label: 'Gate' }, garage: { label: 'Garage Door' } },
                pinLength: 4,
                minAutoClose: 5,
                maxAutoClose: 300,
                defaults: { autoClose: 30, distance: 2.5 },
            },
        });
    }
}

/* ═══════════════════════════ boot ═══════════════════════════ */

setInterval(() => post('heartbeat'), 1000);
sendReady();
