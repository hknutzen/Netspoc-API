package main

/*
=head1 NAME

delete-owner - Delete existing owner entry

=head1 SYNOPSIS

delete-owner name

=head1 COPYRIGHT AND DISCLAIMER

(c) 2020 by Heinz Knutzen <heinz.knutzen@googlemail.com>

http://hknutzen.github.com/Netspoc-API

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.
*/

import (
	"fmt"
	"github.com/hknutzen/Netspoc/go/pkg/abort"
	"github.com/hknutzen/Netspoc/go/pkg/ast"
	"github.com/hknutzen/Netspoc/go/pkg/parser"
	"github.com/hknutzen/Netspoc/go/pkg/printer"
	"io/ioutil"
	"os"
)

func main() {
	usage := func() {
		fmt.Fprintf(os.Stderr,
			"Usage: %s name\n", os.Args[0])
		os.Exit(1)
	}
	count := len(os.Args)
	if count != 2 {
		usage()
	}
	oName := os.Args[1]

	// Read lines of to be changed file from STDIN.
	input, err := ioutil.ReadAll(os.Stdin)
	if err != nil {
		abort.Msg("%v", err)
	}
	output := process(input, oName)
	_, err = os.Stdout.Write(output)
	if err != nil {
		abort.Msg("%v", err)
	}
}

// Find and delete definition of owner.
func process(source []byte, owner string) []byte {
	nodes := parser.ParseFile(source, "STDIN")
	copy := make([]ast.Toplevel, 0, len(nodes)+1)
	owner = "owner:" + owner
	found := false
	for _, toplevel := range nodes {
		if owner == toplevel.GetName() {
			found = true
		} else {
			copy = append(copy, toplevel)
		}
	}
	if !found {
		abort.Msg("Can't find %s", owner)
	}
	return printer.File(copy, source)
}
