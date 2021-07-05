package main

/*
NAME
worker - Process jobs of Netspoc-API

SYNOPSIS
worker FILE ...

COPYRIGHT AND DISCLAIMER
(c) 2021 by Heinz Knutzen <heinz.knutzen@googlemail.com>

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
	"fmt"
	"github.com/hknutzen/Netspoc/go/pkg/ast"
	"github.com/hknutzen/Netspoc/go/pkg/astset"
	"github.com/hknutzen/Netspoc/go/pkg/conf"
	"github.com/hknutzen/Netspoc/go/pkg/fileop"
	"github.com/hknutzen/Netspoc/go/pkg/parser"
	"github.com/hknutzen/Netspoc/go/pkg/printer"
	"io/ioutil"
	"net"
	"os"
	"path"
	"strings"
)

var netspocPath = "netspoc"

type state struct {
	*astset.State
}

func main() {
	// Initialize Conf, especially attribute IgnoreFiles.
	dummyArgs := []string{}
	conf.ConfigFromArgsAndFile(dummyArgs, netspocPath)

	s := new(state)
	var err error
	s.State, err = astset.Read(netspocPath)
	if err != nil {
		// Text of this error message is checked in cvs-worker1.
		abortf("While reading netspoc files: %s", err)
	}
	for _, path := range os.Args[1:] {
		s.doJobFile(path)
	}
	s.Print()
}

type job struct {
	Method string
	Params json.RawMessage
	Crq    string
}

var handler = map[string]func(*state, *job){
	"create_toplevel":  (*state).createToplevel,
	"delete_toplevel":  (*state).deleteToplevel,
	"create_host":      (*state).createHost,
	"modify_host":      (*state).modifyHost,
	"create_owner":     (*state).createOwner,
	"modify_owner":     (*state).modifyOwner,
	"delete_owner":     (*state).deleteOwner,
	"add_to_group":     (*state).addToGroup,
	"create_service":   (*state).createService,
	"delete_service":   (*state).deleteService,
	"add_to_user":      (*state).addToUser,
	"remove_from_user": (*state).removeFromUser,
	"add_to_rule":      (*state).addToRule,
	"remove_from_rule": (*state).removeFromRule,
	"add_rule":         (*state).addRule,
	"delete_rule":      (*state).deleteRule,
}

func (s *state) doJobFile(path string) {
	data, err := ioutil.ReadFile(path)
	if err != nil {
		abortf("While reading file %s: %s", path, err)
	}
	j := new(job)
	err = json.Unmarshal(data, j)
	if err != nil {
		abortf("In JSON file %s: %s", path, err)
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
		abortf("Unknown method '%s'", m)
	}
}

func (s *state) multiJob(j *job) {
	var p struct {
		Jobs []*job
	}
	getParams(j, &p)
	for _, sub := range p.Jobs {
		s.doJob(sub)
	}
}

func (s *state) createHost(j *job) {
	var p struct {
		Network string
		Name    string
		IP      string
		Mask    string
		Owner   string
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
			abortf("Invalid IP address: '%s'", ip)
		}
		m := net.IPMask(net.ParseIP(p.Mask).To4())
		_, bits := m.Size()
		if bits == 0 {
			abortf("Invalid IP mask: '%s'", p.Mask)
		}
		netAddr = (&net.IPNet{IP: i.Mask(m), Mask: m}).String()
		network = ""
	} else {
		network = "network:" + network
	}
	found := s.Modify(func(toplevel ast.Toplevel) bool {
		if n, ok := toplevel.(*ast.Network); ok {
			if network != "" && network == n.Name ||
				netAddr != "" && netAddr == n.GetAttr("ip") {

				// Don't add owner, if already present at network.
				if owner == n.GetAttr("owner") {
					owner = ""
				}

				// Add host.
				h := &ast.Attribute{Name: "host:" + host}
				h.ComplexValue = append(h.ComplexValue, ast.CreateAttr1("ip", ip))
				if owner != "" {
					h.ComplexValue =
						append(h.ComplexValue, ast.CreateAttr1("owner", owner))
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
			abortf("Can't find %s", network)
		} else {
			abortf("Can't find network with 'ip = %s'", netAddr)
		}
	}
}

func (s *state) modifyHost(j *job) {
	var p struct {
		Name  string
		Owner string
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
	found := s.Modify(func(toplevel ast.Toplevel) bool {
		if n, ok := toplevel.(*ast.Network); ok {
			if net != "" && n.Name != net {
				return false
			}
			for _, h := range n.Hosts {
				if h.Name == host {
					h.Change("owner", owner)
					return true
				}
			}
		}
		return false
	})
	if !found {
		abortf("Can't find %s", host)
	}
}

func (s *state) createToplevel(j *job) {
	var p struct {
		Definition string
		File       string
		OkIfExists bool `json:"ok_if_exists"`
	}
	getParams(j, &p)
	obj, err := parser.ParseToplevel([]byte(p.Definition))
	checkErr(err)
	file := path.Clean(p.File)
	if path.IsAbs(file) {
		abortf("Invalid absolute filename: %s", file)
	}
	if file == "" || file[0] == '.' {
		abortf("Invalid filename %s", file)
	}
	// Do nothing if node already exists.
	if p.OkIfExists {
		name := obj.GetName()
		found := false
		s.Modify(func(n ast.Toplevel) bool {
			if name == n.GetName() {
				found = true
			}
			return false
		})
		if found {
			return
		}
	}
	obj.Order()
	s.CreateToplevel(file, obj)
}

func (s *state) deleteToplevel(j *job) {
	var p struct {
		Name string
	}
	getParams(j, &p)
	checkErr(s.DeleteToplevel(p.Name))
}

func (s *state) deleteOwner(j *job) {
	var p struct {
		Name string
	}
	getParams(j, &p)
	name := "owner:" + p.Name
	checkErr(s.DeleteToplevel(name))
}

func (s *state) deleteService(j *job) {
	var p struct {
		Name string
	}
	getParams(j, &p)
	name := "service:" + p.Name
	checkErr(s.DeleteToplevel(name))
}

type jsonMap map[string]interface{}

func getOwnerPath(name string) string {
	file := "owner"
	if strings.HasPrefix(name, "DA_TOKEN_") {
		file += "-token"
	}
	return file
}

func (s *state) createOwner(j *job) {
	var p struct {
		Name       string
		Admins     []string
		Watchers   []string
		OkIfExists int `json:"ok_if_exists"`
	}
	getParams(j, &p)
	watchers := ""
	if p.Watchers != nil {
		watchers = fmt.Sprintf("watchers = %s;", strings.Join(p.Watchers, ", "))
	}
	def := fmt.Sprintf("owner:%s = { admins = %s; %s}",
		p.Name, strings.Join(p.Admins, ", "), watchers)
	params, _ := json.Marshal(jsonMap{
		"definition":   def,
		"file":         getOwnerPath(p.Name),
		"ok_if_exists": p.OkIfExists != 0,
	})
	s.createToplevel(&job{Params: params})
}

func (s *state) modifyOwner(j *job) {
	var p struct {
		Name     string
		Admins   []string
		Watchers []string
	}
	getParams(j, &p)
	owner := "owner:" + p.Name
	checkErr(s.ModifyObj(owner, func(toplevel ast.Toplevel) {
		n := toplevel.(*ast.TopStruct)
		n.ChangeAttr("admins", p.Admins)
		n.ChangeAttr("watchers", p.Watchers)
	}))
}

func (s *state) addToGroup(j *job) {
	var p struct {
		Name   string
		Object string
	}
	getParams(j, &p)
	group := "group:" + p.Name
	checkErr(s.ModifyObj(group, func(toplevel ast.Toplevel) {
		n := toplevel.(*ast.TopList)
		add, err := parser.ParseUnion([]byte(p.Object))
		checkErr(err)
		n.Elements = append(n.Elements, add...)

		// Sort list of objects.
		n.Order()
	}))
}

func getServicePath(name string) string {
	file := "rule"
	if !fileop.IsDir(file) {
		err := os.Mkdir(file, 0777)
		if err != nil {
			abortf("Can't %v", err)
		}
	}
	s0 := strings.ToUpper(name[0:1])
	c0 := s0[0]
	if 'A' <= c0 && c0 <= 'Z' || '0' <= c0 && c0 <= '9' {
		file = path.Join(file, s0)
	} else {
		file = path.Join(file, "other")
	}
	return file
}

type jsonRule struct {
	Action string
	Src    string
	Dst    string
	Prt    string
}

func (s *state) createService(j *job) {
	var p struct {
		Name        string
		Description string
		User        string
		Rules       []jsonRule
	}
	getParams(j, &p)
	rules := ""
	for _, ru := range p.Rules {
		rules += fmt.Sprintf("%s src=%s; dst=%s; prt=%s; ",
			ru.Action, ru.Src, ru.Dst, ru.Prt)
	}
	descr := ""
	if p.Description != "" {
		descr = "description = " + p.Description + "\n"
	}
	def := fmt.Sprintf("service:%s = { %s user = %s; %s }",
		p.Name, descr, p.User, rules)
	params, _ := json.Marshal(jsonMap{
		"definition": def,
		"file":       getServicePath(p.Name),
	})
	s.createToplevel(&job{Params: params})
}

func (s *state) addToUser(j *job) {
	var p struct {
		Service string
		User    string
	}
	getParams(j, &p)
	service := "service:" + p.Service
	checkErr(s.ModifyObj(service, func(toplevel ast.Toplevel) {
		sv := toplevel.(*ast.Service)
		add, err := parser.ParseUnion([]byte(p.User))
		checkErr(err)
		sv.User.Elements = append(sv.User.Elements, add...)
		// Sort list of users.
		sv.Order()
	}))
}

func (s *state) removeFromUser(j *job) {
	var p struct {
		Service string
		User    string
	}
	getParams(j, &p)
	service := "service:" + p.Service
	checkErr(s.ModifyObj(service, func(toplevel ast.Toplevel) {
		sv := toplevel.(*ast.Service)
		delUnion(sv.User, service, -1, p.User)
	}))
}

func (s *state) addToRule(j *job) {
	var p struct {
		Service string
		RuleNum int `json:"rule_num"`
		Src     string
		Dst     string
		Prt     string
	}
	getParams(j, &p)
	service := "service:" + p.Service
	checkErr(s.ModifyObj(service, func(toplevel ast.Toplevel) {
		sv := toplevel.(*ast.Service)
		rule := getRule(sv, p.RuleNum)
		addUnion := func(to *ast.NamedUnion, elements string) {
			if elements != "" {
				add, err := parser.ParseUnion([]byte(elements))
				checkErr(err)
				to.Elements = append(to.Elements, add...)
			}
		}
		addUnion(rule.Src, p.Src)
		addUnion(rule.Dst, p.Dst)
		if p.Prt != "" {
			attr := rule.Prt
			for _, prt := range strings.Split(p.Prt, ",") {
				prt = strings.TrimSpace(prt)
				attr.ValueList = append(attr.ValueList, &ast.Value{Value: prt})
			}
		}
		sv.Order()
	}))
}

func (s *state) removeFromRule(j *job) {
	var p struct {
		Service string
		RuleNum int `json:"rule_num"`
		Src     string
		Dst     string
		Prt     string
	}
	getParams(j, &p)
	service := "service:" + p.Service
	checkErr(s.ModifyObj(service, func(toplevel ast.Toplevel) {
		sv := toplevel.(*ast.Service)
		rule := getRule(sv, p.RuleNum)
		delUnion(rule.Src, service, p.RuleNum, p.Src)
		delUnion(rule.Dst, service, p.RuleNum, p.Dst)
		if p.Prt != "" {
			attr := rule.Prt
		PRT:
			for _, prt := range strings.Split(p.Prt, ",") {
				p1 := strings.ReplaceAll(prt, " ", "")
				l := attr.ValueList
				for i, v := range l {
					p2 := strings.ReplaceAll(v.Value, " ", "")
					if p1 == p2 {
						attr.ValueList = append(l[:i], l[i+1:]...)
						continue PRT
					}
				}
				abortf("Can't find '%s' in rule %d of %s",
					prt, p.RuleNum, service)
			}
		}
		sv.Order()
	}))
}

func (s *state) addRule(j *job) {
	var p struct {
		Service string
		jsonRule
	}
	getParams(j, &p)
	service := "service:" + p.Service
	checkErr(s.ModifyObj(service, func(toplevel ast.Toplevel) {
		sv := toplevel.(*ast.Service)
		addSvRule(sv, &p.jsonRule)
	}))
}

func (s *state) deleteRule(j *job) {
	var p struct {
		Service string
		RuleNum int `json:"rule_num"`
	}
	getParams(j, &p)
	service := "service:" + p.Service
	checkErr(s.ModifyObj(service, func(toplevel ast.Toplevel) {
		sv := toplevel.(*ast.Service)
		idx := getRuleIdx(sv, p.RuleNum)
		sv.Rules = append(sv.Rules[:idx], sv.Rules[idx+1:]...)
	}))
}

func addSvRule(sv *ast.Service, p *jsonRule) {
	rule := new(ast.Rule)
	switch p.Action {
	case "deny":
		rule.Deny = true
	case "permit":
	default:
		abortf("Invalid 'Action': '%s'", p.Action)
	}
	getUnion := func(name string, elements string) *ast.NamedUnion {
		union, err := parser.ParseUnion([]byte(elements))
		checkErr(err)
		return &ast.NamedUnion{Name: name, Elements: union}
	}
	rule.Src = getUnion("src", p.Src)
	rule.Dst = getUnion("dst", p.Dst)
	var prtList []*ast.Value
	for _, prt := range strings.Split(p.Prt, ",") {
		prt = strings.TrimSpace(prt)
		prtList = append(prtList, &ast.Value{Value: prt})
	}
	rule.Prt = &ast.Attribute{Name: "prt", ValueList: prtList}
	l := sv.Rules
	if rule.Deny {
		// Append in front after existing deny rules.
		for i, r := range l {
			if !r.Deny {
				sv.Rules = make([]*ast.Rule, 0, len(l)+1)
				sv.Rules = append(sv.Rules, l[:i]...)
				sv.Rules = append(sv.Rules, rule)
				sv.Rules = append(sv.Rules, l[i:]...)
				break
			}
		}
	} else {
		sv.Rules = append(l, rule)
	}
}

func delUnion(where *ast.NamedUnion, sv string, rNum int, elements string) {
	if elements == "" {
		return
	}
	del, err := parser.ParseUnion([]byte(elements))
	checkErr(err)
OBJ:
	for _, obj1 := range del {
		p1 := printer.Element(obj1)
		l := where.Elements
		for i, obj2 := range l {
			p2 := printer.Element(obj2)
			if p1 == p2 {
				where.Elements = append(l[:i], l[i+1:]...)
				continue OBJ
			}
		}
		num := ""
		if rNum > 1 {
			num = fmt.Sprintf(" of rule %d", rNum)
		}
		abortf("Can't find '%s' in '%s'%s of %s",
			p1, where.Name, num, sv)
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

func getRule(sv *ast.Service, num int) *ast.Rule {
	return sv.Rules[getRuleIdx(sv, num)]
}

func getRuleIdx(sv *ast.Service, num int) int {
	idx := num - 1
	n := len(sv.Rules)
	if idx < 0 || idx >= n {
		abortf("Invalid rule_num %d, have %d rules in %s", idx+1, n, sv.Name)
	}
	return idx
}

func getTypeName(v string) (string, string) {
	parts := strings.SplitN(v, ":", 2)
	if len(parts) != 2 {
		abortf("Expected typed name but got '%s'", v)
	}
	return parts[0], parts[1]
}

func abortf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "Error: "+format+"\n", args...)
	os.Exit(1)
}

func checkErr(err error) {
	if err != nil {
		abortf("%s", err)
	}
}
