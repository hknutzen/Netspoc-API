package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
)

var apiDir, frontend, backend string

func TestQueue(t *testing.T) {
	// Set up PATH, such that commands are searched
	// in $HOME/Netspoc, $HOME/Netspoc-Approve
	home := os.Getenv("HOME")
	netspocDir := home + "/Netspoc"
	approveDir := home + "/Netspoc-Approve"
	os.Setenv("PATH", fmt.Sprintf("%s/bin:%s/bin:%s",
		netspocDir, approveDir, os.Getenv("PATH")))
	apiDir = home + "/Netspoc-API"

	setupFrontend(t)
	setupWWW()
	setupBackend(t)
	setupNetspoc(`-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
`)
	id := addHosts(1, 7)
	pid := startQueue()
	waitJob(id)
	checkGitLog(t, "Multiple files in one commit", "topology",
		`API jobs: 1 2 3 4 5 6 7
CRQ00001 CRQ00002 CRQ00003 CRQ00004 CRQ00005 CRQ00006 CRQ00007

p1
`)
	stopQueue(pid)

	addHosts(8, 12)
	addHost(12) // Duplicate IP
	id = addHosts(13, 14)
	pid = startQueue()
	waitJob(id)
	// Seeing truncated log, because "git clone --depth 1" is used.
	checkGitLog(t, "Multiple files with one error", "topology",
		`API jobs: 14 15
CRQ000013 CRQ000014

API job: 12
CRQ000012
`)

	// Fresh start with cleaned up topology and stopped queue.
	stopQueue(pid)
	changeNetspoc(`-- topology
		network:a = { ip = 10.1.1.0/24; } # Comment
		`)
	id1 := addHostDirect(4)
	id2 := addHost(4) // Add identical job; will fail.
	checkStatus(t, "Job 1 waiting, no worker", id1, "WAITING")
	checkStatus(t, "Job 2 waiting, no worker", id2, "WAITING")
	pid = startQueue()
	time.Sleep(100 * time.Millisecond)
	id3 := addHost(5)
	checkStatus(t, "Job 1 in progress", id1, "INPROGRESS")
	checkStatus(t, "Job 2 in progress", id2, "INPROGRESS")
	checkStatus(t, "New job 3 waiting", id3, "WAITING")
	checkStatus(t, "Unknown job 99", "99", "UNKNOWN")
	waitJob(id3)
	checkStatus(t, "Can't access job 1 from WWW", id1, "DENIED")
	checkStatus(t, "Job 2 with errors", id2,
		`ERROR
Can't modify Netspoc files:
Error: Can't add duplicate definition of 'host:name_10_1_1_4'
`)
	checkStatus(t, "Job 3 success", id3, "FINISHED")
	checkLog(t, "Empty log", "")

	// Check in bad content, so Netspoc stops with errors.
	changeNetspoc(`-- topology
		network:a = { ip = 10.1.1.0/24; }
		network:a = { ip = 10.1.1.0/24; }
		`)
	id = addHost(4)
	waitJob(id)
	checkStatus(t, "API fails on bad content in repository", id,
		`500 Error: API is currently unusable, because someone else has checked in bad files.
 Please try again later.
`)

	// Check in bad content, which API can't read.
	changeNetspoc(`-- topology
		network:a = { ip = 10.1.1.0/24; }  BAD SYNTAX
		`)
	id = addHost(4)
	waitJob(id)
	checkStatus(t, "API fails on illegal syntax in repository", id,
		`500 Error: API is currently unusable, because someone else has checked in bad files.
 Please try again later.
`)

	// Let "scp" fail
	os.WriteFile(backend+"/my-bin/scp",
		[]byte(`#!/bin/sh
		echo "scp: can't connect" >&2
		exit 1
		`), 0700)
	id = addHost(4)
	pid = startQueue()
	time.Sleep(1000 * time.Millisecond)
	checkLog(t, "scp failed", "scp: can't connect\n")
	stopQueue(pid)

	// Let "ssh" fail
	os.WriteFile(backend+"/my-bin/ssh",
		[]byte(`#!/bin/sh
		echo "ssh: can't connect" >&2
		exit 1
		`), 0700)
	pid = startQueue()
	time.Sleep(1000 * time.Millisecond)
	stopQueue(pid)
	checkLog(t, "ssh failed", "ssh: can't connect\n")
}

// Prepare directory for frontend, store name in global variable frontend.
func setupFrontend(t *testing.T) {
	// Create working directory.
	frontend = t.TempDir()
	// Make worker scripts available.
	os.Symlink(apiDir+"/frontend", frontend+"/bin")
}

// Prepare directory for backend, prepare fake versions of ssh and scp.
// Store name of directory in global variable backend.
func setupBackend(t *testing.T) {
	// Create working directory, set as home directory and as current directory.
	backend = t.TempDir()
	os.Setenv("HOME", backend)
	os.Chdir(backend)
	// Install versions of ssh and scp that use sh and cp instead.
	os.Mkdir("my-bin", 0700)
	os.WriteFile("my-bin/ssh",
		[]byte(fmt.Sprintf(`#!/bin/bash
getopts q OPTION && shift
shift		# ignore name of remote host
if [ $# -gt 0 ] ; then
    sh -c "cd %s; $*"
else
    sh -s -c "cd %s"
fi
`, frontend, frontend)), 0700)
	os.WriteFile("my-bin/scp",
		[]byte(fmt.Sprintf(`#!/bin/bash
getopts q OPTION && shift
replace () { echo $1 | sed -E 's,^[^:]+:,%s/,'; }
FROM=$(replace $1)
TO=$(replace $2)
cp $FROM $TO
`, frontend)), 0700)
	os.Setenv("PATH", fmt.Sprintf("%s/my-bin:%s", backend, os.Getenv("PATH")))
	// Make worker scripts available.
	os.Symlink(apiDir+"/backend", "bin")
}

func setupNetspoc(input string) {
	// Prevent warnings from git.
	exec.Command("git", "config", "--global", "user.name", "Test User").Run()
	exec.Command("git", "config", "--global", "user.email", "").Run()
	exec.Command("git", "config", "--global", "init.defaultBranch", "master").Run()
	exec.Command("git", "config", "--global", "pull.rebase", "true").Run()

	tmp := path.Join(backend, "tmp-git")
	os.Mkdir(tmp, 0700)
	prepareDir(tmp, input)
	os.Chdir(tmp)
	// Initialize git repository.
	exec.Command("git", "init", "--quiet").Run()
	exec.Command("git", "add", ".").Run()
	exec.Command("git", "commit", "-m", "initial").Run()
	os.Chdir(backend)
	// Checkout into bare directory
	bare := path.Join(backend, "netspoc.git")
	exec.Command("git", "clone", "--quiet", "--bare", tmp, bare).Run()
	os.Setenv("NETSPOC_GIT", "file://"+bare)
	os.RemoveAll(tmp)
	// Checkout into directory 'netspoc'
	exec.Command("git", "clone", "--quiet", bare, "netspoc").Run()

	// Create config file .netspoc-approve for newpolicy
	os.Mkdir("policydb", 0700)
	os.Mkdir("lock", 0700)
	os.WriteFile(".netspoc-approve",
		[]byte(fmt.Sprintf(`
netspocdir = %s/policydb
lockfiledir = %s/lock
netspoc_git = file://%s
`, backend, backend, bare)), 0600)

	// Create files for Netspoc-Approve and create compile.log file.
	exec.Command("newpolicy.pl").Run()
}

func changeNetspoc(input string) {
	os.Chdir(backend)
	prepareDir("netspoc", input)
	os.Chdir("netspoc")
	exec.Command("git", "add", "--all").Run()
	exec.Command("git", "commit", "-m", "test").Run()
	exec.Command("git", "pull", "--quiet").Run()
	exec.Command("git", "push", "--quiet").Run()
	os.Chdir(backend)
}

// Fill directory with files from input.
// Parts of input are marked by single lines of dashes
// followed by a filename.
func prepareDir(dir, input string) {
	re := regexp.MustCompile(`(?ms)^-+[ ]*\S+[ ]*\n`)
	il := re.FindAllStringIndex(input, -1)
	if il == nil {
		log.Fatal("Missing filename before first input block")
	}
	if il[0][0] != 0 {
		log.Fatal("Missing file marker in first line")
	}
	for i, p := range il {
		marker := input[p[0] : p[1]-1] // without trailing "\n"
		pName := strings.Trim(marker, "- ")
		file := path.Join(dir, pName)
		start := p[1]
		end := len(input)
		if i+1 < len(il) {
			end = il[i+1][0]
		}
		data := input[start:end]
		dir := path.Dir(file)
		if err := os.MkdirAll(dir, 0755); err != nil {
			log.Fatalf("Can't create directory for '%s': %v", file, err)
		}
		if err := os.WriteFile(file, []byte(data), 0644); err != nil {
			log.Fatal(err)
		}
	}
}

var server *httptest.Server

func setupWWW() {
	os.Setenv("HOME", frontend)
	os.Chdir(frontend)
	cmd := exec.Command("bin/salted-hash")
	cmd.Stdin = strings.NewReader("test")
	out, err := cmd.Output()
	out = bytes.TrimSpace(out)
	if err != nil {
		log.Fatal(err)
	}
	os.WriteFile("config",
		[]byte(fmt.Sprintf(`{"user": {"test": {"hash": "%s"}}}`,
			string(out))), 0600)
	if err = loadConfig(); err != nil {
		log.Fatal(err)
	}
	server = httptest.NewServer(http.HandlerFunc(handleRequest))
}

func wwwCall(endpoint, data string) (int, []byte) {
	os.Setenv("HOME", frontend)
	os.Chdir(frontend)
	resp, err := http.DefaultClient.Post(
		server.URL+endpoint, "application/json", strings.NewReader(data))
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

// Wait for results of background job.
func waitJob(id string) {
	fName := frontend + "/finished/" + id
	for {
		if _, err := os.Stat(fName); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// Process queue in background with new process group.
func startQueue() int {
	os.Setenv("HOME", backend)
	os.Chdir(backend)
	cmd := exec.Command("bin/process-queue", "localhost", "bin/git-worker")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	ch := make(chan int)
	go func() {
		if err := cmd.Start(); err != nil {
			panic(err)
		}
		ch <- cmd.Process.Pid
		cmd.Wait()
	}()
	return <-ch
}

// Stop process group, i.e. background job with all its children.
func stopQueue(pid int) {
	syscall.Kill(-pid, syscall.SIGKILL)
}

func checkStatus(t *testing.T, title, id, expected string) {
	t.Run(title, func(t *testing.T) {
		data := fmt.Sprintf(`{ "id": "%s", "user": "test", "pass": "test" }`, id)
		httpStat, bytes := wwwCall("/job-status", data)
		var got string
		if httpStat == http.StatusOK {
			var s struct {
				Status, Message string
			}
			json.Unmarshal(bytes, &s)
			got = s.Status
			if m := s.Message; m != "" {
				got += "\n" + m
			}
		} else {
			got = strconv.Itoa(httpStat) + " " + string(bytes)
		}
		if d := cmp.Diff(expected, got); d != "" {
			t.Error(d)
		}
	})
}

func checkLog(t *testing.T, title, expected string) {
	t.Run(title, func(t *testing.T) {
		file := backend + "/log"
		exec.Command("touch", file).Run()
		cmd := exec.Command("grep", "-v", "^Date: ", file)
		got, _ := cmd.Output()
		if d := cmp.Diff(expected, string(got)); d != "" {
			t.Error(d)
		}
		os.Remove(file)
	})
}

func checkGitLog(t *testing.T, title, file, expected string) {
	t.Run(title, func(t *testing.T) {
		os.Chdir(backend)
		os.Chdir("netspoc")
		cmd := exec.Command("git", "log", "--format=format:%B", file)
		got, _ := cmd.Output()
		os.Chdir(backend)
		if d := cmp.Diff(expected, string(got)); d != "" {
			t.Error(d)
		}
	})
}

func addHost(i int) string {
	_, bytes := wwwCall("/add-job", getHostJob(i, "test"))
	var s struct {
		ID string
	}
	json.Unmarshal(bytes, &s)
	return s.ID
}

func addHosts(start, end int) string {
	id := ""
	for i := start; i <= end; i++ {
		id = addHost(i)
	}
	return id
}

func addHostDirect(i int) string {
	os.Setenv("HOME", frontend)
	os.Chdir(frontend)
	cmd := exec.Command("bin/add-job")
	cmd.Stdin = strings.NewReader(getHostJob(i, ""))
	out, err := cmd.Output()
	if err != nil {
		panic(err)
	}
	return string(out)
}

func getHostJob(i int, user string) string {
	return fmt.Sprintf(`{
"user": "%s",
"pass": "test",
"method": "add",
"params": {
 "path": "network:a,host:name_10_1_1_%d",
 "value": { "ip": "10.1.1.%d" }
},
"crq": "CRQ0000%d"
}`, user, i, i, i)
}
