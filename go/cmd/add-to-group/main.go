package main

/*
=head1 NAME

add-to-group - Add object to existing group

=head1 SYNOPSIS

add-to-group group-name object

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
	"strings"
)

func main() {
	usage := func() {
		fmt.Fprintf(os.Stderr,
			"Usage: %s group-name object\n", os.Args[0])
		os.Exit(1)
	}
	count := len(os.Args)
	if count != 3 {
		usage()
	}
	group, object := os.Args[1], os.Args[2]

	input, err := ioutil.ReadAll(os.Stdin)
	if err != nil {
		abort.Msg("%v", err)
	}
	output := process(input, group, object)
	_, err = os.Stdout.Write(output)
	if err != nil {
		abort.Msg("%v", err)
	}
}

func process(source []byte, group, object string) []byte {
	nodes := parser.ParseFile(source, "STDIN")
	for _, toplevel := range nodes {
		if n, ok := toplevel.(*ast.TopList); ok {
			typ, name := getTypeName(n.Name)
			if typ == "group" && name == group {

				// Add object.
				typ, name := getTypeName(object)
				obj := &ast.NamedRef{TypedElt: ast.TypedElt{Type: typ}, Name: name}
				n.Elements = append(n.Elements, obj)

				// Sort list of objects.
				n.Order()
			}
		}
	}
	return printer.File(nodes, source)
}

func getTypeName(v string) (string, string) {
	parts := strings.SplitN(v, ":", 2)
	if len(parts) != 2 {
		return "", ""
	}
	return parts[0], parts[1]
}
