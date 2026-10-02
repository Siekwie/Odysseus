package network

// JSON messages exchanged on ws://<host>/signal. Media does not go over this socket.
//
// Server -> viewer
//   hello      sent on connect and after a successful auth; describes the host
//   answer     SDP answer
//   candidate  ICE candidate
//   state      stream changed (monitor switch, size, encoder, viewer count)
//   error      request refused; `code` is machine readable
//
// Viewer -> server
//   auth       password / PIN (when hello says one is needed)
//   offer      SDP offer
//   candidate  ICE candidate
//   keyframe   ask for an IDR
//   monitor    switch the captured monitor (index)
//   input      one mouse / keyboard event (see Input fields)
//   bye        clean disconnect

// Signal_Message is the union of every inbound message; unused fields stay zero.
Signal_Message :: struct {
	type:      string `json:"type"`,
	sdp:       string `json:"sdp,omitempty"`,
	candidate: string `json:"candidate,omitempty"`,
	mid:       string `json:"sdpMid,omitempty"`,
	password:  string `json:"password,omitempty"`,
	index:     int    `json:"index,omitempty"`,

	// input
	ev:     string `json:"ev,omitempty"`,     // "move" | "down" | "up" | "wheel" | "key"
	x:      f64    `json:"x,omitempty"`,      // 0..1 across the captured monitor
	y:      f64    `json:"y,omitempty"`,
	button: int    `json:"button,omitempty"`, // MouseEvent.button
	dx:     f64    `json:"dx,omitempty"`,     // wheel delta in CSS pixels
	dy:     f64    `json:"dy,omitempty"`,
	key:    string `json:"key,omitempty"`,    // KeyboardEvent.code
	down:   bool   `json:"down,omitempty"`,
}

Answer_Message :: struct {
	type: string `json:"type"`,
	sdp:  string `json:"sdp"`,
}

Candidate_Message :: struct {
	type:      string `json:"type"`,
	candidate: string `json:"candidate"`,
	mid:       string `json:"sdpMid"`,
}

Error_Message :: struct {
	type:    string `json:"type"`,
	code:    string `json:"code"`, // "auth" | "busy" | "capture" | "denied" | "codec" | "peer" | "monitor" | "input"
	message: string `json:"message"`,
}

Monitor_Message :: struct {
	index:   int    `json:"index"`,
	name:    string `json:"name"`,
	width:   int    `json:"width"`,
	height:  int    `json:"height"`,
	primary: bool   `json:"primary"`,
}

Hello_Message :: struct {
	type:        string            `json:"type"`,
	version:     string            `json:"version"`,
	authorized:  bool              `json:"authorized"`,  // false: send "auth" before "offer"
	audio:       bool              `json:"audio"`,       // offer an audio transceiver
	input:       bool              `json:"input"`,       // host allows remote control
	control:     bool              `json:"control"`,     // this viewer may send input
	control_pin: bool              `json:"controlPin"`,  // control needs an "auth" with the PIN first
	cursor:      bool              `json:"cursor"`,      // the host draws its cursor into the stream
	monitor:     int               `json:"monitor"`,
	monitors:    []Monitor_Message `json:"monitors"`,
}

State_Message :: struct {
	type:    string `json:"type"`,
	monitor: int    `json:"monitor"`,
	width:   int    `json:"width"`,
	height:  int    `json:"height"`,
	fps:     int    `json:"fps"`,
	encoder: string `json:"encoder"`,
	capture: string `json:"capture"`,
	viewers: int    `json:"viewers"`,
}
