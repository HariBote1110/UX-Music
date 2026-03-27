package discord

import (
	"sync"
	"time"

	"github.com/hugolgst/rich-go/client"
)

const discordClientID = "1417754671895806062"

// DiscordRPC manages Discord Rich Presence
type DiscordRPC struct {
	mu             sync.Mutex
	connected      bool
	currentDetails string
	currentState   string
	startTime      time.Time
}

var Instance = &DiscordRPC{}

// DiscordActivity represents the activity to display
type DiscordActivity struct {
	Title  string `json:"title"`
	Artist string `json:"artist"`
}

// Connect initializes the Discord RPC connection
func (d *DiscordRPC) Connect() error {
	d.mu.Lock()
	defer d.mu.Unlock()

	if d.connected {
		return nil
	}

	err := client.Login(discordClientID)
	if err != nil {
		return err
	}

	d.connected = true
	return nil
}

// SetActivity updates the Discord Rich Presence
func (d *DiscordRPC) SetActivity(activity DiscordActivity) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	if !d.connected {
		if err := client.Login(discordClientID); err != nil {
			return err
		}
		d.connected = true
	}

	details := activity.Title
	if len(details) > 128 {
		details = details[:128]
	}
	state := "by " + activity.Artist
	if len(state) > 128 {
		state = state[:128]
	}

	if d.currentDetails == details && d.currentState == state {
		return nil
	}

	d.currentDetails = details
	d.currentState = state
	d.startTime = time.Now()

	err := client.SetActivity(client.Activity{
		Details:    details,
		State:      state,
		LargeImage: "ux_music_icon",
		LargeText:  "UX Music",
		Timestamps: &client.Timestamps{
			Start: &d.startTime,
		},
	})

	return err
}

// ClearActivity clears the Discord Rich Presence
func (d *DiscordRPC) ClearActivity() error {
	d.mu.Lock()
	defer d.mu.Unlock()

	d.currentDetails = ""
	d.currentState = ""
	return nil
}

// Disconnect closes the Discord RPC connection
func (d *DiscordRPC) Disconnect() {
	d.mu.Lock()
	defer d.mu.Unlock()

	if d.connected {
		client.Logout()
		d.connected = false
	}
}
