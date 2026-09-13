// Temporary diagnostic: what does the server actually return in usync for
// regular (non-business) users? Run with the app STOPPED (one session, one
// socket). Prints the parsed result plus keeps socket DEBUG logging on so
// the raw XML lands in stderr.
package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"time"

	_ "modernc.org/sqlite"

	waLog "go.mau.fi/whatsmeow/util/log"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
)

func main() {
	sessionDir := os.Getenv("WW_SESSION_DIR")
	if sessionDir == "" {
		sessionDir = os.Getenv("HOME") + "/Library/Application Support/WhatsAppWork"
	}
	rawDB, err := sql.Open("sqlite", "file:"+sessionDir+"/session.db?_pragma=busy_timeout(10000)")
	if err != nil {
		panic(err)
	}
	db := sqlstore.NewWithDB(rawDB, "sqlite", debugLog{})
	if err != nil {
		panic(err)
	}
	devices, err := db.GetAllDevices(context.Background())
	if err != nil {
		panic(err)
	}
	if len(devices) == 0 {
		panic("no device in session store")
	}
	dev := devices[0]
	if os.Getenv("WW_RESET") != "" {
		_ = dev.Delete(context.Background())
		return
	}
	cli := whatsmeow.NewClient(dev, debugLog{})
	go func() {
		for i := 0; i < 40; i++ {
			time.Sleep(1 * time.Second)
			if cli.IsLoggedIn() && cli.IsConnected() {
				break
			}
		}
		time.Sleep(2 * time.Second)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		jids := []types.JID{}
		for _, s := range os.Args[1:] {
			j, err := types.ParseJID(s)
			if err == nil {
				jids = append(jids, j)
			}
		}
		infos, err := cli.GetUserInfo(ctx, jids)
		if err != nil {
			fmt.Println("PROBE usync error:", err)
		} else {
			for jid, info := range infos {
				vn := ""
				if info.VerifiedName != nil && info.VerifiedName.Details != nil {
					vn = info.VerifiedName.Details.GetVerifiedName()
				}
				fmt.Printf("PROBE jid=%s verified=%q status=%q picture=%s lid=%s\n",
					jid, vn, info.Status, info.PictureID, info.LID)
			}
		}
		cli.Disconnect()
		time.Sleep(500 * time.Millisecond)
		os.Exit(0)
	}()
	if err := cli.Connect(); err != nil {
		panic(err)
	}
	time.Sleep(60 * time.Second)
	fmt.Println("PROBE timeout")
	_ = 0
}

type debugLog struct{}
func (debugLog) Errorf(f string, a ...any) { fmt.Printf("WA-E "+f+"\n", a...) }
func (debugLog) Warnf(f string, a ...any)  { fmt.Printf("WA-W "+f+"\n", a...) }
func (debugLog) Infof(f string, a ...any)   { fmt.Printf("WA-I "+f+"\n", a...) }
func (debugLog) Debugf(f string, a ...any)  { fmt.Printf("WA-D "+f+"\n", a...) }
func (debugLog) Sub(module string) waLog.Logger { return debugLog{} }
