package main

import (
	"encoding/json/jsontext"
	"encoding/json/v2"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"
	"github.com/hknutzen/testtxt"
)

type descr struct {
	Title   string
	Netspoc string
	Other   string
	Job     string
	Verbose bool
	Diff    string
	Error   string
	LogFile string
	Log     string
}

func TestGit(t *testing.T) {
	// Set up PATH, such that commands are searched in $HOME/Netspoc
	home := os.Getenv("HOME")
	netspocDir := home + "/Netspoc"
	os.Setenv("PATH", fmt.Sprintf("%s/bin:%s", netspocDir, os.Getenv("PATH")))
	apiDir := home + "/Netspoc-API"
	dataFiles, _ := filepath.Glob("testdata/*.t")
	for _, file := range dataFiles {
		base := path.Base(file)
		t.Run(base, func(t *testing.T) {
			var l []descr
			if err := testtxt.ParseFile(file, &l); err != nil {
				t.Fatal(err)
			}
			for _, descr := range l {
				t.Run(descr.Title, func(t *testing.T) {
					runTest(t, descr, apiDir)
				})
			}
		})
	}
}

func runTest(t *testing.T, d descr, apiDir string) {
	// Create working directory, set as home directory and as current directory.
	workDir := t.TempDir()
	os.Setenv("HOME", workDir)
	os.Chdir(workDir)

	// Make worker scripts available.
	os.Symlink(apiDir+"/backend", "bin")
	setupNetspoc(t, d.Netspoc, workDir)

	// Prepare job file(s).
	var jobFiles []string
	if d.Job != "" {
		var jobs [][]byte
		var p struct{ Jobs []jsontext.Value }
		if json.Unmarshal([]byte(d.Job), p) == nil {
			for _, job := range p.Jobs {
				jobs = append(jobs, []byte(job))
			}
		} else {
			jobs = [][]byte{[]byte(d.Job)}
		}
		for i, job := range jobs {
			name := fmt.Sprintf("job-%d", i+1)
			if err := os.WriteFile(name, job, 0644); err != nil {
				t.Fatal(err)
			}
			jobFiles = append(jobFiles, name)
		}
	}

	callWorker := func(which string) bool {
		var l []string
		if d.Verbose {
			l = append(l, "-v")
		}
		l = append(l, jobFiles...)
		got, err := exec.Command("bin/git-worker"+which, l...).CombinedOutput()
		stdErr := string(got)
		stdErr = strings.ReplaceAll(stdErr, workDir, "~")
		if err != nil {
			if _, ok := err.(*exec.ExitError); !ok {
				t.Fatal(err)
			}
			if d.Error == "" {
				t.Error("Unexpected failure")
			}
			if d := cmp.Diff(d.Error, stdErr); d != "" {
				t.Error(d)
			}
			return false
		}
		return true
	}
	// Checkout files from Git, apply changes and run Netspoc.
	success := callWorker("1")
	if success {
		if d.Error != "" {
			t.Error("Unexpected success")
			return
		}
		if d.Diff == "" {
			t.Error("Missing diff specification")
			return
		}
	}

	// Collect and simplify diff before check in.
	// Show diff even if Netspoc failed.
	//diff -x .git -ruN orig/netspoc/rule/S netspoc/rule/S
	//--- orig/netspoc/rule/S 1970-01-01 01:00:00.000000000 +0100
	//+++ netspoc/rule/S      2022-08-19 14:46:29.026666333 +0200
	//@@ -0,0 +1,6 @@
	if d.Diff != "" {
		diff, _ := exec.Command("sh", "-c",
			"diff -x .git -ruN orig/netspoc netspoc"+
				"| sed "+
				` -e 's/^+++ \([^ \t]\+\).*$/\1/'`+
				" -e '/^diff -x/d'"+
				" -e '/^--- /d'"+
				" -e 's/^ $//'").CombinedOutput()
		if d := cmp.Diff(d.Diff, diff); d != "" {
			t.Error(d)
		}
	}

	if !success {
		return
	}

	// Simulate changes by other user.
	if d.Other != "" {
		exec.Command("git", "clone", "--quiet", "--depth", "1",
			"netspoc.git", "other").Run()
		testtxt.PrepareFileOrDir(t, "other", d.Other)
		exec.Command("sh", "-c",
			"cd other; git add --all; git commit -q -m other; git push -q").Run()
	}

	// Try to check in changes.
	callWorker("2")

	if d.LogFile != "" {
		log, _ := exec.Command("sh", "-c", fmt.Sprintf(
			"cd netspoc; git log -1 --format=format:%%B %s", d.LogFile)).Output()
		if d := cmp.Diff(d.Log, log); d != "" {
			t.Error(d)
		}
	}
}

func setupNetspoc(t *testing.T, input string, workDir string) {
	// Prevent warnings from git.
	exec.Command("git", "config", "--global", "user.name", "Test User").Run()
	exec.Command("git", "config", "--global", "user.email", "").Run()
	exec.Command("git", "config", "--global", "init.defaultBranch", "master").Run()
	exec.Command("git", "config", "--global", "pull.rebase", "true").Run()

	tmp := path.Join(workDir, "tmp-git")
	os.Mkdir(tmp, 0700)
	testtxt.PrepareFileOrDir(t, tmp, input)
	os.Chdir(tmp)
	// Initialize git repository.
	exec.Command("git", "init", "--quiet").Run()
	exec.Command("git", "add", ".").Run()
	exec.Command("git", "commit", "-m", "initial").Run()
	os.Chdir(workDir)
	// Checkout into bare directory
	bare := path.Join(workDir, "netspoc.git")
	exec.Command("git", "clone", "--quiet", "--bare", tmp, bare).Run()
	os.RemoveAll(tmp)
	// Checkout into directory 'netspoc'
	//exec.Command("git", "clone", "--quiet", bare, "netspoc").Run()
}

func changeNetspoc(t *testing.T, input string, workDir string) {
	os.Chdir(workDir)
	testtxt.PrepareFileOrDir(t, "netspoc", input)
	os.Chdir("netspoc")
	exec.Command("git", "add", "--all").Run()
	exec.Command("git", "commit", "-m", "test").Run()
	exec.Command("git", "pull", "--quiet").Run()
	exec.Command("git", "push", "--quiet").Run()
	os.Chdir(workDir)
}

func checkLog(t *testing.T, title, expected string, workDir string) {
	t.Run(title, func(t *testing.T) {
		file := workDir + "/log"
		exec.Command("touch", file).Run()
		cmd := exec.Command("grep", "-v", "^Date: ", file)
		got, _ := cmd.Output()
		if d := cmp.Diff(expected, string(got)); d != "" {
			t.Error(d)
		}
		os.Remove(file)
	})
}

func checkGitLog(t *testing.T, title, file, expected string, workDir string) {
	t.Run(title, func(t *testing.T) {
		os.Chdir(workDir)
		os.Chdir("netspoc")
		cmd := exec.Command("git", "log", "--format=format:%B", file)
		got, _ := cmd.Output()
		os.Chdir(workDir)
		if d := cmp.Diff(expected, string(got)); d != "" {
			t.Error(d)
		}
	})
}
