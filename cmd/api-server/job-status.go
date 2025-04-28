package main

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
)

// Show processing status of given job as result.
// Result is JSON with
// attribute "status" and value:
// - WAITING
// - INPROGRESS
// - FINISHED
// - DENIED
// - UNKNOWN
// or
//   - ERROR
//     with additional attribute "message".
func jobStatus(w http.ResponseWriter, req jsonArgs) {
	exists := func(p string) bool {
		_, err := os.Stat(p)
		return err == nil
	}
	var status string
	result := jsonMap{}
	id := req.Id
	if exists("waiting/" + id) {
		status = "WAITING"
	} else if exists("inprogress/" + id) {
		status = "INPROGRESS"
	} else if data, err := os.ReadFile("finished/" + id); err == nil {
		var job jsonArgs
		if err := json.Unmarshal(data, &job); err != nil {
			internalErr(w, "Job has invalid JSON: "+err.Error())
			return
		}
		if req.User != job.User {
			status = "DENIED"
		} else {
			data, err := os.ReadFile("result/" + id)
			if err != nil {
				internalErr(w, err.Error())
				return
			}
			if len(data) != 0 {
				msg := string(data)
				if strings.Contains(msg, "try again") {
					msg := strings.TrimSuffix(msg, "\n")
					// Client should add job again on this result.
					internalErr(w, msg)
					return
				}
				status = "ERROR"
				result["message"] = msg
			} else {
				status = "FINISHED"
			}
		}
	} else {
		status = "UNKNOWN"
	}
	result["status"] = status
	enc := json.NewEncoder(w)
	enc.Encode(result)
}
