package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"golang.org/x/crypto/bcrypt"
)

// Create salted hash from cleartext password read from stdin.
func main() {
	pass, _ := io.ReadAll(os.Stdin)
	pass, _, _ = bytes.Cut(pass, []byte("\n"))
	hash, _ := bcrypt.GenerateFromPassword(pass, bcrypt.MinCost)
	fmt.Println(string(hash))
}
