package input

// One row per physical key of a US keyboard, named like the browser's
// KeyboardEvent.code, with the key's number on every platform:
//
//   evdev  Linux input-event-codes.h KEY_* (X11 keycode = evdev + 8)
//   scan   Windows scan code, set 1 make code; `ext` adds the E0 prefix
//          (KEYEVENTF_EXTENDEDKEY)
//   vk     Windows virtual-key code, for keys whose scan code is unreliable
//          (Pause and PrintScreen have multi-byte sequences, F13-F24 and the
//          media keys vary between keyboards). Wins over `scan` when set.
//   mac    macOS virtual key code (kVK_*)
//
// NONE means the platform has no such key.
// Physical positions are sent, not characters: the host's keyboard layout
// decides what a key types, exactly like a local keyboard.

NONE :: -1

Key :: struct {
	code:  string, // KeyboardEvent.code
	evdev: i32,
	scan:  i32,
	ext:   bool,
	vk:    i32,
	mac:   i32,
}

KEYS := [?]Key{
	// Letters
	{"KeyA", 30, 0x1E, false, 0, 0x00},
	{"KeyB", 48, 0x30, false, 0, 0x0B},
	{"KeyC", 46, 0x2E, false, 0, 0x08},
	{"KeyD", 32, 0x20, false, 0, 0x02},
	{"KeyE", 18, 0x12, false, 0, 0x0E},
	{"KeyF", 33, 0x21, false, 0, 0x03},
	{"KeyG", 34, 0x22, false, 0, 0x05},
	{"KeyH", 35, 0x23, false, 0, 0x04},
	{"KeyI", 23, 0x17, false, 0, 0x22},
	{"KeyJ", 36, 0x24, false, 0, 0x26},
	{"KeyK", 37, 0x25, false, 0, 0x28},
	{"KeyL", 38, 0x26, false, 0, 0x25},
	{"KeyM", 50, 0x32, false, 0, 0x2E},
	{"KeyN", 49, 0x31, false, 0, 0x2D},
	{"KeyO", 24, 0x18, false, 0, 0x1F},
	{"KeyP", 25, 0x19, false, 0, 0x23},
	{"KeyQ", 16, 0x10, false, 0, 0x0C},
	{"KeyR", 19, 0x13, false, 0, 0x0F},
	{"KeyS", 31, 0x1F, false, 0, 0x01},
	{"KeyT", 20, 0x14, false, 0, 0x11},
	{"KeyU", 22, 0x16, false, 0, 0x20},
	{"KeyV", 47, 0x2F, false, 0, 0x09},
	{"KeyW", 17, 0x11, false, 0, 0x0D},
	{"KeyX", 45, 0x2D, false, 0, 0x07},
	{"KeyY", 21, 0x15, false, 0, 0x10},
	{"KeyZ", 44, 0x2C, false, 0, 0x06},

	// Digit row
	{"Digit1", 2,  0x02, false, 0, 0x12},
	{"Digit2", 3,  0x03, false, 0, 0x13},
	{"Digit3", 4,  0x04, false, 0, 0x14},
	{"Digit4", 5,  0x05, false, 0, 0x15},
	{"Digit5", 6,  0x06, false, 0, 0x17},
	{"Digit6", 7,  0x07, false, 0, 0x16},
	{"Digit7", 8,  0x08, false, 0, 0x1A},
	{"Digit8", 9,  0x09, false, 0, 0x1C},
	{"Digit9", 10, 0x0A, false, 0, 0x19},
	{"Digit0", 11, 0x0B, false, 0, 0x1D},

	// Punctuation
	{"Minus",         12, 0x0C, false, 0, 0x1B},
	{"Equal",         13, 0x0D, false, 0, 0x18},
	{"BracketLeft",   26, 0x1A, false, 0, 0x21},
	{"BracketRight",  27, 0x1B, false, 0, 0x1E},
	{"Backslash",     43, 0x2B, false, 0, 0x2A},
	{"Semicolon",     39, 0x27, false, 0, 0x29},
	{"Quote",         40, 0x28, false, 0, 0x27},
	{"Backquote",     41, 0x29, false, 0, 0x32},
	{"Comma",         51, 0x33, false, 0, 0x2B},
	{"Period",        52, 0x34, false, 0, 0x2F},
	{"Slash",         53, 0x35, false, 0, 0x2C},
	{"IntlBackslash", 86, 0x56, false, 0, 0x0A}, // the extra key of ISO keyboards (kVK_ISO_Section)

	// Editing and whitespace
	{"Enter",     28, 0x1C, false, 0, 0x24},
	{"Escape",    1,  0x01, false, 0, 0x35},
	{"Backspace", 14, 0x0E, false, 0, 0x33},
	{"Tab",       15, 0x0F, false, 0, 0x30},
	{"Space",     57, 0x39, false, 0, 0x31},
	{"CapsLock",  58, 0x3A, false, 0, 0x39},

	// Function keys
	{"F1",  59, 0x3B, false, 0, 0x7A},
	{"F2",  60, 0x3C, false, 0, 0x78},
	{"F3",  61, 0x3D, false, 0, 0x63},
	{"F4",  62, 0x3E, false, 0, 0x76},
	{"F5",  63, 0x3F, false, 0, 0x60},
	{"F6",  64, 0x40, false, 0, 0x61},
	{"F7",  65, 0x41, false, 0, 0x62},
	{"F8",  66, 0x42, false, 0, 0x64},
	{"F9",  67, 0x43, false, 0, 0x65},
	{"F10", 68, 0x44, false, 0, 0x6D},
	{"F11", 87, 0x57, false, 0, 0x67},
	{"F12", 88, 0x58, false, 0, 0x6F},
	{"F13", 183, NONE, false, 0x7C, 0x69},
	{"F14", 184, NONE, false, 0x7D, 0x6B},
	{"F15", 185, NONE, false, 0x7E, 0x71},
	{"F16", 186, NONE, false, 0x7F, 0x6A},
	{"F17", 187, NONE, false, 0x80, 0x40},
	{"F18", 188, NONE, false, 0x81, 0x4F},
	{"F19", 189, NONE, false, 0x82, 0x50},
	{"F20", 190, NONE, false, 0x83, 0x5A},
	{"F21", 191, NONE, false, 0x84, NONE},
	{"F22", 192, NONE, false, 0x85, NONE},
	{"F23", 193, NONE, false, 0x86, NONE},
	{"F24", 194, NONE, false, 0x87, NONE},

	// System keys. Macs have no such keys; a PC keyboard on a Mac sends
	// F13/F14/F15 for PrintScreen/ScrollLock/Pause and Help for Insert.
	{"PrintScreen", 99,  0x37, true,  0x2C, 0x69}, // VK_SNAPSHOT
	{"ScrollLock",  70,  0x46, false, 0,    0x6B},
	{"Pause",       119, NONE, false, 0x13, 0x71}, // VK_PAUSE; scan code is E1 1D 45
	{"Insert",      110, 0x52, true,  0,    0x72},
	{"ContextMenu", 127, 0x5D, true,  0,    0x6E}, // KEY_COMPOSE, which is what X11 calls Menu

	// Navigation (all extended on Windows)
	{"Home",       102, 0x47, true, 0, 0x73},
	{"PageUp",     104, 0x49, true, 0, 0x74},
	{"Delete",     111, 0x53, true, 0, 0x75},
	{"End",        107, 0x4F, true, 0, 0x77},
	{"PageDown",   109, 0x51, true, 0, 0x79},
	{"ArrowLeft",  105, 0x4B, true, 0, 0x7B},
	{"ArrowRight", 106, 0x4D, true, 0, 0x7C},
	{"ArrowDown",  108, 0x50, true, 0, 0x7D},
	{"ArrowUp",    103, 0x48, true, 0, 0x7E},

	// Numpad. NumLock is Clear on a Mac.
	{"NumLock",        69, 0x45, false, 0, 0x47},
	{"Numpad0",        82, 0x52, false, 0, 0x52},
	{"Numpad1",        79, 0x4F, false, 0, 0x53},
	{"Numpad2",        80, 0x50, false, 0, 0x54},
	{"Numpad3",        81, 0x51, false, 0, 0x55},
	{"Numpad4",        75, 0x4B, false, 0, 0x56},
	{"Numpad5",        76, 0x4C, false, 0, 0x57},
	{"Numpad6",        77, 0x4D, false, 0, 0x58},
	{"Numpad7",        71, 0x47, false, 0, 0x59},
	{"Numpad8",        72, 0x48, false, 0, 0x5B},
	{"Numpad9",        73, 0x49, false, 0, 0x5C},
	{"NumpadAdd",      78, 0x4E, false, 0, 0x45},
	{"NumpadSubtract", 74, 0x4A, false, 0, 0x4E},
	{"NumpadMultiply", 55, 0x37, false, 0, 0x43},
	{"NumpadDivide",   98, 0x35, true,  0, 0x4B},
	{"NumpadDecimal",  83, 0x53, false, 0, 0x41},
	{"NumpadEnter",    96, 0x1C, true,  0, 0x4C},

	// Modifiers. Command on a Mac is Meta (Windows key) on a PC.
	{"ShiftLeft",    42,  0x2A, false, 0, 0x38},
	{"ShiftRight",   54,  0x36, false, 0, 0x3C},
	{"ControlLeft",  29,  0x1D, false, 0, 0x3B},
	{"ControlRight", 97,  0x1D, true,  0, 0x3E},
	{"AltLeft",      56,  0x38, false, 0, 0x3A},
	{"AltRight",     100, 0x38, true,  0, 0x3D},
	{"MetaLeft",     125, 0x5B, true,  0, 0x37},
	{"MetaRight",    126, 0x5C, true,  0, 0x36},

	// Media. macOS has the codes, but the system volume only follows
	// NX_SYSDEFINED events, so these are likely to do nothing there.
	{"AudioVolumeMute", 113, 0x20, true, 0xAD, 0x4A},
	{"AudioVolumeDown", 114, 0x2E, true, 0xAE, 0x49},
	{"AudioVolumeUp",   115, 0x30, true, 0xAF, 0x48},
}

// key_index returns the position of code in KEYS, or -1.
key_index :: proc(code: string) -> int {
	for k, i in KEYS {
		if k.code == code {
			return i
		}
	}
	return -1
}

// key_lookup finds the row for a KeyboardEvent.code.
key_lookup :: proc(code: string) -> (key: Key, ok: bool) {
	i := key_index(code)
	if i < 0 {
		return {}, false
	}
	return KEYS[i], true
}
