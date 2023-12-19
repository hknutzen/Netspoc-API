package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"

	"github.com/go-ldap/ldap/v3"
	"golang.org/x/crypto/bcrypt"
)

var confFile = "config"

type config struct {
	LDAPURI string `json:"ldap_uri"`
	User    map[string]struct {
		LDAP bool
		Hash string
	}
}

var conf config

func main() {
	// Start in home directory to find
	// - config file in ./config
	// - scripts in bin/
	os.Chdir(os.Getenv("HOME"))
	if err := loadConfig(); err != nil {
		log.Fatal(err)
	}
	http.HandleFunc("/", handleRequest)
	port := os.Getenv("LISTENPORT")
	if port == "" {
		log.Fatal(`Error: missing environment variable "LISTENPORT"`)
	}
	bind := os.Getenv("LISTENADDRESS") + ":" + port
	log.Print("Listening on ", bind)
	log.Fatal(http.ListenAndServe(bind, nil))
}

func handleRequest(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		badRequest(w, "Can't read body: "+err.Error())
		return
	}
	var job jsonArgs
	if err := json.Unmarshal(body, &job); err != nil {
		badRequest(w, err.Error())
		return
	}
	if authenticate(w, job) {
		switch r.URL.Path {
		case "/add-job":
			addJob(w, body)
		case "/job-status":
			jobStatus(w, job)
		default:
			badRequest(w, "Unknown path")
		}
	}
}

type jsonMap map[string]interface{}

func addJob(w http.ResponseWriter, body []byte) {
	var job jsonMap
	json.Unmarshal(body, &job)
	// Delete password from request, must not be stored in queue.
	delete(job, "pass")
	body, _ = json.Marshal(job)
	cmd := exec.Command("bin/add-job")
	cmd.Stdin = bytes.NewBuffer(body)
	out, err := cmd.CombinedOutput()
	if err != nil {
		internalErr(w, string(out)+" "+err.Error())
	} else {
		enc := json.NewEncoder(w)
		enc.Encode(jsonMap{"id": string(out)})
	}
}

type jsonArgs struct {
	User string
	Pass string
	Id   string
}

func jobStatus(w http.ResponseWriter, job jsonArgs) {
	cmd := exec.Command("bin/job-status", job.Id, job.User)
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg, _ := strings.CutSuffix(string(out), "\n")
		internalErr(w, msg)
	} else {
		w.Write(out)
	}
}

func authenticate(w http.ResponseWriter, job jsonArgs) bool {
	user := job.User
	if user == "" {
		badRequest(w, "Missing 'user'")
		return false
	}
	pass := job.Pass
	if pass == "" {
		badRequest(w, "Missing 'pass'")
		return false
	}
	userConf, found := conf.User[user]
	if !found {
		badRequest(w, "User is not authorized")
		return false
	}
	if hash := userConf.Hash; hash != "" {
		if bcrypt.CompareHashAndPassword([]byte(hash), []byte(pass)) != nil {
			badRequest(w, "Local authentication failed")
			return false
		}
	} else if userConf.LDAP {
		l, err := ldap.DialURL(conf.LDAPURI)
		if err != nil {
			internalErr(w, "LDAP connect failed: "+err.Error())
			return false
		}
		defer l.Close()
		if l.Bind(user, pass) != nil {
			badRequest(w, "LDAP authentication failed")
			return false
		}
	} else {
		internalErr(w, "No authentication method configured")
		return false
	}
	return true
}

func loadConfig() error {
	bytes, err := os.ReadFile(confFile)
	if err != nil {
		return fmt.Errorf("Can't %s ", err)
	}
	err = json.Unmarshal(bytes, &conf)
	if err != nil {
		return fmt.Errorf("error while reading %s: %s", confFile, err)
	}
	for _, auth := range conf.User {
		if auth.LDAP && conf.LDAPURI == "" {
			return fmt.Errorf("No 'ldap_uri' has been configured")
		}
	}
	return nil
}

func badRequest(w http.ResponseWriter, m string) {
	http.Error(w, m, http.StatusBadRequest)
}

func internalErr(w http.ResponseWriter, m string) {
	http.Error(w, m, http.StatusInternalServerError)
}
