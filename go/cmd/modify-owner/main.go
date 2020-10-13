package main

/*
=head1 NAME

modify-owner - Modify existing owner entry

=head1 SYNOPSIS

modify-owner name admin-list watcher-list

=head1 DESCRIPTION

List is a comma separated list of values or 'null'.
Replaces attribute 'admins' and/or 'watchers' with given list
or leaves attribute unchanged if value is 'null'.

=head1 COPYRIGHT AND DISCLAIMER

(c) 2019 by Heinz Knutzen <heinz.knutzen@googlemail.com>

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
			"Usage: %s name admin-list watcher-list\n", os.Args[0])
		os.Exit(1)
	}
	if len(os.Args) != 4 {
		usage()
	}

	oName := os.Args[1]
	admins := os.Args[2]
	watchers := os.Args[3]

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

// Find and modify definition of owner.
func process(source []byte, owner, admins, watchers string) []byte {

	removeAttr := func(obj *ast.TopStruct, name string) {
		copy := make([]*ast.Attribute, 0, len(obj.Attributes)-1)
		for _, a := range obj.Attributes {
			if a.Name != name {
				copy = append(copy, a)
			}
		}
		obj.Attributes = copy
	}

	replaceAttr := func(obj *ast.TopStruct, attr *ast.Attribute) {
		for i, a := range obj.Attributes {
			if a.Name == attr.Name {
				obj.Attributes[i] = attr
				return
			}
		}
		obj.Attributes = append(obj.Attributes, attr)
	}

	changeAttr := func(obj *ast.TopStruct, name, list string) {
		switch list {
		case "null":
			return
		case "":
			removeAttr(obj, name)
			return
		}

		attr := new(ast.Attribute)
		attr.Name = name
		l := strings.Split(list, ",")
		sort.Strings(l)
		for _, part := range l {
			v := new(ast.Value)
			v.Value = part
			attr.ValueList = append(attr.ValueList, v)
		}
		replaceAttr(obj, attr)
	}

	nodes := parser.ParseFile(source, "STDIN")
	found := false
	for _, toplevel := range nodes {
		if n, ok := toplevel.(*ast.TopStruct); ok {
			typ, name := getTypeName(n.Name)
			if typ == "owner" && name == owner {
				changeAttr(n, "admins", admins)
				changeAttr(n, "watchers", watchers)
				found = true
				break
			}
		}
	}
	if !found {
		abort.Msg("Can't find owner:%s", owner)
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
