package main

/*
=head1 NAME

modify-host - Modify attributes of existing host entry

=head1 SYNOPSIS

modify-host name owner

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
			"Usage: %s name owner\n", os.Args[0])
		os.Exit(1)
	}
	if len(os.Args) != 3 {
		usage()
	}

	host := os.Args[1]
	owner := os.Args[2]

	// Read lines of to be changed file from STDIN.
	input, err := ioutil.ReadAll(os.Stdin)
	if err != nil {
		abort.Msg("%v", err)
	}
	output := process(input, host, owner)
	_, err = os.Stdout.Write(output)
	if err != nil {
		abort.Msg("%v", err)
	}
}

// Find and modify definition of host.
func process(source []byte, host, owner string) []byte {

	// Special handling for ID-host:
	// - remove trailing network name from host name,
	// - limit search to this network definition
	net := ""
	if strings.HasPrefix(host, "id:") {
		// ID host is extended by network name: host:id:a.b@c.d.net_name
		parts := strings.Split(host, ".")
		net = "network:" + parts[len(parts)-1]
		host = strings.Join(parts[:len(parts)-1], ".")
	}
	host = "host:" + host

	removeAttr := func(obj *ast.Attribute, name string) {
		copy := make([]*ast.Attribute, 0, len(obj.ComplexValue)-1)
		for _, a := range obj.ComplexValue {
			if a.Name != name {
				copy = append(copy, a)
			}
		}
		obj.ComplexValue = copy
	}

	replaceAttr := func(obj *ast.Attribute, attr *ast.Attribute) {
		for i, a := range obj.ComplexValue {
			if a.Name == attr.Name {
				obj.ComplexValue[i] = attr
				return
			}
		}
		obj.ComplexValue = append(obj.ComplexValue, attr)
	}

	changeAttr := func(obj *ast.Attribute, name, value string) {
		if value == "null" {
			removeAttr(obj, name)
			return
		}
		attr := &ast.Attribute{
			Name:      name,
			ValueList: []*ast.Value{{Value: value}},
		}
		replaceAttr(obj, attr)
	}

	nodes := parser.ParseFile(source, "STDIN")
	found := false
TOPLEVEL:
	for _, toplevel := range nodes {
		if n, ok := toplevel.(*ast.Network); ok {
			if net != "" && n.Name != net {
				continue
			}
			for _, h := range n.Hosts {
				if h.Name == host {
					changeAttr(h, "owner", owner)
					found = true
					break TOPLEVEL
				}
			}
		}
	}
	if !found {
		abort.Msg("Can't find %s", host)
	}
	return printer.File(nodes, source)
}
