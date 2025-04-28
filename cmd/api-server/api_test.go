package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"
	"github.com/hknutzen/testtxt"
)

type descr struct {
	Title    string
	Input    string
	Output   string
	URL      string
	Request  string
	Response string
	Status   int
}

func TestAPI(t *testing.T) {
	dir, _ := os.Getwd()
	home := os.Getenv("HOME")
	dataFiles, _ := filepath.Glob(dir + "/testdata/*.t")
	for _, file := range dataFiles {
		t.Run(path.Base(file), func(t *testing.T) {
			var l []descr
			if err := testtxt.ParseFile(file, &l); err != nil {
				t.Fatal(err)
			}
			for _, d := range l {
				t.Run(d.Title, func(t *testing.T) {
					testHandler(t, d)
				})
			}
		})
	}
	// Clean up for other tests to run.
	os.Chdir(dir)
	os.Setenv("HOME", home)
}

func testHandler(t *testing.T, d descr) {
	workDir := t.TempDir()
	os.Chdir(workDir)
	os.Setenv("HOME", workDir)
	testtxt.PrepareInDir(t, workDir, "", d.Input)

	conf = config{}
	if err := loadConfig(); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(
		http.MethodPost, d.URL, strings.NewReader(d.Request))
	resp := httptest.NewRecorder()
	handleRequest(resp, req)
	if resp.Code != d.Status {
		t.Errorf("Want status '%d', got '%d'", d.Status, resp.Code)
	}
	if resp.Code == 200 {
		jsonEq(t, d.Response, resp.Body.Bytes())
	} else {
		eq(t, d.Response, resp.Body.String())
	}
	if d.Output != "" {
		dirCheck(t, d.Output, workDir)
	}
}

func eq(t *testing.T, expected, got string) {
	if d := cmp.Diff(expected, got); d != "" {
		t.Error(d)
	}
}

func dirCheck(t *testing.T, spec, dir string) {
	// Blocks of expected output are split by single lines of dashes,
	// followed by file name.
	re := regexp.MustCompile(`(?ms)^-+[ ]*\S+[ ]*\n`)
	il := re.FindAllStringIndex(spec, -1)

	if il == nil || il[0][0] != 0 {
		t.Fatal("Output spec must start with dashed line")
	}
	for i, p := range il {
		marker := spec[p[0] : p[1]-1] // without trailing "\n"
		pName := strings.Trim(marker, "- ")
		if pName == "" {
			t.Fatal("Missing file name in dashed line of output spec")
		}
		start := p[1]
		end := len(spec)
		if i+1 < len(il) {
			end = il[i+1][0]
		}
		block := spec[start:end]

		t.Run(pName, func(t *testing.T) {
			data, err := os.ReadFile(path.Join(dir, pName))
			if err != nil {
				t.Fatal(err)
			}
			if pName == "job-counter" {
				eq(t, block, string(data))
			} else {
				jsonEq(t, block, data)
			}
		})
	}
}

func jsonEq(t *testing.T, expected string, got []byte) {
	normalize := func(d []byte) string {
		// Leave POLICY file of export-netspoc unchanged
		if len(d) > 0 && d[0] == '#' {
			return string(d)
		}
		var v any
		if err := json.Unmarshal(d, &v); err != nil {
			t.Fatal(err)
		}
		var b bytes.Buffer
		enc := json.NewEncoder(&b)
		enc.SetEscapeHTML(false)
		enc.SetIndent("", " ")
		enc.Encode(v)
		return b.String()
	}
	eq(t, normalize([]byte(expected)), normalize(got))
}

func runCmd(t *testing.T, line string) {
	args := strings.Fields(line)
	cmd := exec.Command(args[0], args[1:]...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("Command failed: %q: %v", line, string(out))
	}
}
