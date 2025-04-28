package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"syscall"
)

// File name for storing number of last stored job.
const counter = "job-counter"

type jsonMap map[string]any

// Read job from body, add job to queue, give ID of job as result.
func addJob(w http.ResponseWriter, body []byte) {
	var job jsonMap
	json.Unmarshal(body, &job)
	// Delete password from request, must not be stored in queue.
	delete(job, "pass")
	// Jobs are stored in directory waiting/ in files 1, 2, 3, ...
	os.Mkdir("waiting", 0755)
	fh, err := os.OpenFile(counter, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		internalErr(w, err.Error())
	}
	// Lock counter for exclusive access.
	err = syscall.Flock(int(fh.Fd()), syscall.LOCK_EX)
	if err != nil {
		internalErr(w, "Can't get lock: "+err.Error())
	}
	// Read job count; is empty on first run.
	count := 0
	fmt.Fscan(fh, &count)
	// Increment count and write back.
	count++
	fh.Seek(0, 0)
	_, err = fmt.Fprintln(fh, count)
	if err != nil {
		internalErr(w, "Writing job-counter: "+err.Error())
	}
	fh.Close()
	// Write job to temp file to prevent reading of partial written
	// file.
	os.Mkdir("tmp", 0755)
	tmpName := fmt.Sprintf("tmp/%d", count)
	fh, err = os.Create(tmpName)
	if err != nil {
		internalErr(w, err.Error())
	}
	enc := json.NewEncoder(fh)
	enc.SetEscapeHTML(false)
	enc.Encode(job)
	fh.Close()
	// Move temp file to queue.
	jobName := fmt.Sprintf("waiting/%d", count)
	err = os.Rename(tmpName, jobName)
	if err != nil {
		internalErr(w, err.Error())
	}
	// Give ID of created job as answer.
	enc = json.NewEncoder(w)
	enc.Encode(jsonMap{"id": strconv.Itoa(count)})
}
