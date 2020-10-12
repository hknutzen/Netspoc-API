package main

/*
=head1 NAME

create-owner - Create new owner entry

=head1 SYNOPSIS

create-owner owner-name admin,... [watcher,...]

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
	"sort"
	"strings"
)

func main() {
	usage := func() {
		fmt.Fprintf(os.Stderr,
			"Usage: %s owner-name admin,... [watcher,...]\n", os.Args[0])
		os.Exit(1)
	}
	count := len(os.Args)
	if count < 3 || count > 4 {
		usage()
	}

	oName := os.Args[1]
	admins := os.Args[2]
	watchers := ""
	if count == 4 {
		watchers = os.Args[3]
	}

	// Read lines of to be changed file from STDIN.
	input, err := ioutil.ReadAll(os.Stdin)
	if err != nil {
		abort.Msg("%v", err)
	}
	output := process(input, oName, admins, watchers)
	_, err = os.Stdout.Write(output)
	if err != nil {
		abort.Msg("%v", err)
	}
}

// Owners are assumed to be sorted by name.
// Compare case insensitive.
// Insert before next larger owner.
// If no larger owner found, insert at end of file.
func process(source []byte, owner, admins, watchers string) []byte {
	nodes := parser.ParseFile(source, "STDIN")
	copy := make([]ast.Toplevel, 0, len(nodes)+1)

	createAttr := func(name, list string) *ast.Attribute {
		attr := new(ast.Attribute)
		attr.Name = name
		l := strings.Split(list, ",")
		sort.Strings(l)
		for _, part := range l {
			v := new(ast.Value)
			v.Value = part
			attr.ValueList = append(attr.ValueList, v)
		}
		return attr
	}

	// Insert new owner.
	inserted := false
	insert := func() {
		obj := new(ast.TopStruct)
		obj.Name = "owner:" + owner
		aAttr := createAttr("admins", admins)
		obj.Attributes = append(obj.Attributes, aAttr)
		if watchers != "" && watchers != "null" {
			wAttr := createAttr("watchers", watchers)
			obj.Attributes = append(obj.Attributes, wAttr)
		}
		copy = append(copy, obj)
	}
	oLower := strings.ToLower(owner)
	for i, toplevel := range nodes {
		if n, ok := toplevel.(*ast.TopStruct); ok {
			typ, name := getTypeName(n.Name)
			if typ == "owner" && strings.ToLower(name) > oLower {
				insert()
				inserted = true
				copy = append(copy, nodes[i:]...)
				break
			}
		}
		copy = append(copy, toplevel)
	}
	if !inserted {
		insert()
	}
	return printer.File(copy, source)
}

func getTypeName(v string) (string, string) {
	parts := strings.SplitN(v, ":", 2)
	if len(parts) != 2 {
		return "", ""
	}
	return parts[0], parts[1]
}
