package main

/*
=head1 NAME

create-host - Create new host entry inside existing network

=head1 SYNOPSIS

create-host network-name host-name host-ip [host-owner]

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
			"Usage: %s network-name host-name host-ip [host-owner]\n", os.Args[0])
		os.Exit(1)
	}
	count := len(os.Args)
	if count < 4 || count > 5 {
		usage()
	}
	network, host, ip := os.Args[1], os.Args[2], os.Args[3]
	owner := ""
	if count == 5 {
		owner = os.Args[4]
	}

	input, err := ioutil.ReadAll(os.Stdin)
	if err != nil {
		abort.Msg("%v", err)
	}
	output := process(input, network, host, ip, owner)
	_, err = os.Stdout.Write(output)
	if err != nil {
		abort.Msg("%v", err)
	}
}

func process(source []byte, network, host, ip, owner string) []byte {
	nodes := parser.ParseFile(source, "STDIN")
	for _, toplevel := range nodes {
		if n, ok := toplevel.(*ast.Network); ok {
			if strings.HasSuffix(n.Name, ":"+network) {

				// Don't add owner, if already present at network.
				if owner == getAttr(n, "owner") {
					owner = ""
				}

				// Add host.
				h := &ast.Attribute{Name: "host:" + host}
				h.ComplexValue = append(h.ComplexValue, createAttr("ip", ip))
				if owner != "" {
					h.ComplexValue =
						append(h.ComplexValue, createAttr("owner", owner))
				}
				n.Hosts = append(n.Hosts, h)

				// Sort list of hosts.
				n.Order()
			}
		}
	}
	return printer.File(nodes, source)
}

func createAttr(k, v string) *ast.Attribute {
	val := &ast.Value{Value: v}
	return &ast.Attribute{Name: k, ValueList: []*ast.Value{val}}
}

func getAttr(n *ast.Network, name string) string {
	for _, a := range n.Attributes {
		if a.Name == name {
			l := a.ValueList
			if len(l) > 0 {
				return l[0].Value
			} else {
				return ""
			}
		}
	}
	return ""
}
