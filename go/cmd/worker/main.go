package main

/*
NAME
worker - Process jobs of Netspoc-API

SYNOPSIS
worker FILE ...

COPYRIGHT AND DISCLAIMER
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
	"encoding/json"
	"github.com/hknutzen/Netspoc/go/pkg/abort"
	"github.com/hknutzen/Netspoc/go/pkg/ast"
	"github.com/hknutzen/Netspoc/go/pkg/conf"
	"github.com/hknutzen/Netspoc/go/pkg/fileop"
	"github.com/hknutzen/Netspoc/go/pkg/filetree"
	"github.com/hknutzen/Netspoc/go/pkg/parser"
	"github.com/hknutzen/Netspoc/go/pkg/printer"
	"io/ioutil"
	"net"
	"os"
	"sort"
	"strings"
)

var netspocPath = "netspoc"

func main() {
	// Initialize Conf, especially attribute IgnoreFiles.
	dummyArgs := []string{}
	conf.ConfigFromArgsAndFile(dummyArgs, netspocPath)

	s := readNetspoc()
	for _, path := range os.Args[1:] {
		s.doJobFile(path)
	}
	s.printNetspoc()
}

type state struct {
	fileNodes [][]ast.Toplevel
	sources   [][]byte
	files     []string
	changed   map[string]bool
}

func readNetspoc() *state {
	s := new(state)
	s.changed = make(map[string]bool)
	filetree.Walk(netspocPath, func(input *filetree.Context) {
		source := []byte(input.Data)
		path := input.Path
		nodes := parser.ParseFile(source, path)
		s.fileNodes = append(s.fileNodes, nodes)
		s.files = append(s.files, path)
		s.sources = append(s.sources, source)
	})
	return s
}

func (s *state) modifyAST(f func(ast.Toplevel) bool) bool {
	someModified := false
	for i, l := range s.fileNodes {
		modified := false
		for _, n := range l {
			if f(n) {
				modified = true
			}
		}
		if modified {
			s.changed[s.files[i]] = true
			someModified = true
		}
	}
	return someModified
}

func (s *state) printNetspoc() {
	for i, path := range s.files {
		if s.changed[path] {
			p := printer.File(s.fileNodes[i], s.sources[i])
			err := fileop.Overwrite(path, p)
			if err != nil {
				abort.Msg("%v", err)
			}
		}
	}
}

type job struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Crq    string          `json:"crq"`
}

var handler = map[string]func(*state, *job){
	"create_host":  (*state).createHost,
	"modify_host":  (*state).modifyHost,
	"create_owner": (*state).createOwner,
	"modify_owner": (*state).modifyOwner,
	"delete_owner": (*state).deleteOwner,
	"add_to_group": (*state).addToGroup,
}

func (s *state) doJobFile(path string) {
	data, e := ioutil.ReadFile(path)
	if e != nil {
		abort.Msg("While reading file %s: %s", path, e)
	}
	j := new(job)
	e = json.Unmarshal(data, j)
	if e != nil {
		abort.Msg("In JSON file %s: %s", path, e)
	}
	s.doJob(j)
}

func (s *state) doJob(j *job) {
	m := j.Method
	if m == "multi_job" {
		s.multiJob(j)
		return
	}
	if fn, found := handler[m]; found {
		fn(s, j)
	} else {
		abort.Msg("Unknown method '%s'", m)
	}
}

func (s *state) multiJob(j *job) {
	var p struct {
		Jobs []*job `json:"jobs"`
	}
	getParams(j, &p)
	for _, sub := range p.Jobs {
		s.doJob(sub)
	}
}

func (s *state) createHost(j *job) {
	var p struct {
		Network string `json:"network"`
		Name    string `json:"name"`
		IP      string `json:"ip"`
		Mask    string `json:"mask"`
		Owner   string `json:"owner"`
	}
	getParams(j, &p)
	network := p.Network
	host := p.Name
	ip := p.IP
	owner := p.Owner

	// Search network matching given ip and mask.
	var netAddr string
	if network == "[auto]" {
		i := net.ParseIP(ip).To4()
		if i == nil {
			abort.Msg("Invalid IP address: '%s'", ip)
		}
		m := net.IPMask(net.ParseIP(p.Mask).To4())
		_, bits := m.Size()
		if bits == 0 {
			abort.Msg("Invalid IP mask: '%s'", p.Mask)
		}
		netAddr = (&net.IPNet{IP: i.Mask(m), Mask: m}).String()
		network = ""
	} else {
		network = "network:" + network
	}
	found := s.modifyAST(func(toplevel ast.Toplevel) bool {
		if n, ok := toplevel.(*ast.Network); ok {
			if network != "" && network == n.Name ||
				netAddr != "" && netAddr == getAttr(n, "ip") {

				// Don't add owner, if already present at network.
				if owner == getAttr(n, "owner") {
					owner = ""
				}

				// Add host.
				h := &ast.Attribute{Name: "host:" + host}
				h.ComplexValue = append(h.ComplexValue, createAttr1("ip", ip))
				if owner != "" {
					h.ComplexValue =
						append(h.ComplexValue, createAttr1("owner", owner))
				}
				n.Hosts = append(n.Hosts, h)

				// Sort list of hosts.
				n.Order()
				return true
			}
		}
		return false
	})
	if !found {
		if network != "" {
			abort.Msg("Can't find %s", network)
		} else {
			abort.Msg("Can't find network with 'ip = %s'", netAddr)
		}
	}
}

func (s *state) modifyHost(j *job) {
	var p struct {
		Name  string `json:"name"`
		Owner string `json:"owner"`
	}
	getParams(j, &p)
	host := p.Name
	owner := p.Owner

	// Special handling for ID-host:
	// - remove trailing network name from host name,
	// - limit search to this network definition
	net := ""
	if strings.HasPrefix(host, "id:") {
		// ID host is extended by network name: host:id:a.b@c.d.net_name
		parts := strings.Split(host, ".")
		l := len(parts) - 1
		net = "network:" + parts[l]
		host = strings.Join(parts[:l], ".")
	}
	host = "host:" + host
	found := s.modifyAST(func(toplevel ast.Toplevel) bool {
		if n, ok := toplevel.(*ast.Network); ok {
			if net != "" && n.Name != net {
				return false
			}
			for _, h := range n.Hosts {
				if h.Name == host {
					changeAttr(h, "owner", owner)
					return true
				}
			}
		}
		return false
	})
	if !found {
		abort.Msg("Can't find %s", host)
	}
}

func getOwnerPath(owner string) string {
	file := "netspoc/owner"
	if strings.HasPrefix(owner, "DA_TOKEN_") {
		file += "-token"
	}
	return file
}

func (s *state) createOwner(j *job) {
	var p struct {
		Name       string   `json:"name"`
		Admins     []string `json:"admins"`
		Watchers   []string `json:"watchers"`
		OkIfExists int      `json:"ok_if_exists"`
	}
	getParams(j, &p)
	owner := p.Name
	file := getOwnerPath(owner)
	idx := -1
	for i, f := range s.files {
		if f == file {
			idx = i
		}
	}
	if idx == -1 {
		idx = len(s.files)
		s.files = append(s.files, file)
		s.fileNodes = append(s.fileNodes, nil)
		s.sources = append(s.sources, nil)
	}

	nodes := s.fileNodes[idx]
	cp := make([]ast.Toplevel, 0, len(nodes)+1)
	// Insert new owner.
	inserted := false
	insert := func() {
		obj := new(ast.TopStruct)
		obj.Name = "owner:" + owner
		aAttr := createAttr("admins", p.Admins)
		obj.Attributes = append(obj.Attributes, aAttr)
		if p.Watchers != nil {
			wAttr := createAttr("watchers", p.Watchers)
			obj.Attributes = append(obj.Attributes, wAttr)
		}
		cp = append(cp, obj)
	}
	oLower := strings.ToLower(owner)
	for i2, toplevel := range nodes {
		if n, ok := toplevel.(*ast.TopStruct); ok {
			typ, name := getTypeName(n.Name)
			if typ == "owner" && strings.ToLower(name) >= oLower {
				if !(p.OkIfExists != 0 && name == owner) {
					insert()
				}
				inserted = true
				cp = append(cp, nodes[i2:]...)
				break
			}
		}
		cp = append(cp, toplevel)
	}
	if !inserted {
		insert()
	}
	s.fileNodes[idx] = cp
	s.changed[file] = true
}

func (s *state) modifyOwner(j *job) {
	var p struct {
		Name     string   `json:"name"`
		Admins   []string `json:"admins"`
		Watchers []string `json:"watchers"`
	}
	getParams(j, &p)
	owner := "owner:" + p.Name
	found := s.modifyAST(func(toplevel ast.Toplevel) bool {
		if n, ok := toplevel.(*ast.TopStruct); ok {
			if owner == toplevel.GetName() {
				changeTopAttr(n, "admins", p.Admins)
				changeTopAttr(n, "watchers", p.Watchers)
				return true
			}
		}
		return false
	})
	if !found {
		abort.Msg("Can't find %s", owner)
	}
}

func (s *state) deleteOwner(j *job) {
	var p struct {
		Name string `json:"name"`
	}
	getParams(j, &p)
	owner := "owner:" + p.Name
	found := false
FILE:
	for i, nodes := range s.fileNodes {
		cp := make([]ast.Toplevel, 0, len(nodes))
		for _, toplevel := range nodes {
			if owner == toplevel.GetName() {
				found = true
			} else {
				cp = append(cp, toplevel)
			}
		}
		if found {
			s.fileNodes[i] = cp
			s.changed[s.files[i]] = true
			break FILE
		}
	}
	if !found {
		abort.Msg("Can't find %s", owner)
	}

}

func (s *state) addToGroup(j *job) {
	var p struct {
		Name   string `json:"name"`
		Object string `json:"object"`
	}
	getParams(j, &p)
	group := "group:" + p.Name
	object := p.Object
	found := s.modifyAST(func(toplevel ast.Toplevel) bool {
		if n, ok := toplevel.(*ast.TopList); ok {
			if group == toplevel.GetName() {

				// Add object.
				typ, name := getTypeName(object)
				obj := &ast.NamedRef{TypedElt: ast.TypedElt{Type: typ}, Name: name}
				n.Elements = append(n.Elements, obj)

				// Sort list of objects.
				n.Order()
				return true
			}
		}
		return false
	})
	if !found {
		abort.Msg("Can't find %s", group)
	}
}

func getParams(j *job, p interface{}) {
	if j.Params != nil {
		err := json.Unmarshal(j.Params, p)
		if err != nil {
			panic(err)
		}
	}
}

func changeTopAttr(obj *ast.TopStruct, name string, l []string) {
	if l == nil {
		return
	} else if len(l) == 0 {
		removeTopAttr(obj, name)
		return
	}

	attr := new(ast.Attribute)
	attr.Name = name
	sort.Strings(l)
	for _, part := range l {
		v := new(ast.Value)
		v.Value = part
		attr.ValueList = append(attr.ValueList, v)
	}
	replaceTopAttr(obj, attr)
}

func removeTopAttr(obj *ast.TopStruct, name string) {
	copy := make([]*ast.Attribute, 0, len(obj.Attributes)-1)
	for _, a := range obj.Attributes {
		if a.Name != name {
			copy = append(copy, a)
		}
	}
	obj.Attributes = copy
}

func replaceTopAttr(obj *ast.TopStruct, attr *ast.Attribute) {
	for i, a := range obj.Attributes {
		if a.Name == attr.Name {
			obj.Attributes[i] = attr
			return
		}
	}
	obj.Attributes = append(obj.Attributes, attr)
}

func changeAttr(obj *ast.Attribute, name, value string) {
	if value == "" {
		removeAttr(obj, name)
		return
	}
	attr := &ast.Attribute{
		Name:      name,
		ValueList: []*ast.Value{{Value: value}},
	}
	replaceAttr(obj, attr)
}

func removeAttr(obj *ast.Attribute, name string) {
	cp := make([]*ast.Attribute, 0, len(obj.ComplexValue)-1)
	for _, a := range obj.ComplexValue {
		if a.Name != name {
			cp = append(cp, a)
		}
	}
	obj.ComplexValue = cp
}

func replaceAttr(obj *ast.Attribute, attr *ast.Attribute) {
	for i, a := range obj.ComplexValue {
		if a.Name == attr.Name {
			obj.ComplexValue[i] = attr
			return
		}
	}
	obj.ComplexValue = append(obj.ComplexValue, attr)
}

func createAttr1(k, v string) *ast.Attribute {
	return createAttr(k, []string{v})
}

func createAttr(name string, l []string) *ast.Attribute {
	sort.Strings(l)
	vl := make([]*ast.Value, len(l))
	for i, part := range l {
		vl[i] = &ast.Value{Value: part}
	}
	return &ast.Attribute{Name: name, ValueList: vl}
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

func getTypeName(v string) (string, string) {
	parts := strings.SplitN(v, ":", 2)
	if len(parts) != 2 {
		return "", ""
	}
	return parts[0], parts[1]
}
