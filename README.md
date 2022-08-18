
## Netspoc-API

Netspoc-API is a web service to automatically change text files of a
Netspoc configuration.

---

* [Asynchronous processing](#asynchronous-processing)
* [Authentication](#authentication)
* [Jobs](#jobs)
  * [add](#add)
  * [delete](#delete)
  * [set](#set)
  * [create_host](#create_host)
  * [modify_host](#modify_host)
  * [multi_job](#multi_job)
* [Deprecated methods](#deprecated-methods)
  * [create_owner](#create_owner)
  * [modify_owner](#modify_owner)
  * [delete_owner](#delete_owner)
  * [add_to_group](#add_to_group)


### Asynchronous processing

Netspoc-API processes jobs asyncronously. After posting a job to
```http:SERVER/add-job``` the server returns a job-id as JSON:
```{ "id" : <job-id> }```.

The status of a job is requested by posting ```{ "id" : <job-id> }``` to
```http:SERVER/job-status```.
This results in JSON data with attribute ```status``` and optional
```message```.

Status is one of:

- WAITING, job is waiting in queue.
- INPROGRESS, processing of job has started.
- FINISHED, processing of job has finished without errors.
- ERROR, job has finished with errors; no changes have been made.
         The error message can be found in attribute ```message```.
- UNKNOWN, job is not or no longer known.
- DENIED, access denied, job was queued by some other user.

After getting status FINISHED or ERROR, the job is removed from the system. A status request for the same job will result in status UNKNOWN afterwards.

### Authentication

Each posted request must add attributes ```user``` and ```pass``` for
authentictation

### Jobs

Jobs are send as JSON data.
Each job has at least these attributes:

- method: Type of job.
- params: JSON object with additional attributes.
   Different methods have different set of parameters.
- crq: Description of change request, used for commit message.

#### add
#### delete
#### set

These are generic methods to modify any part of the Netspoc configuration.

Method 'add' adds
- a new toplevel node,
- a new attribute inside a node or
- a new value inside the list of values of an attribute.
It is an error
- to add a toplevel node that already exists or
- to add to an attribute, that has a structured value.

Method 'delete' deletes
- an existing toplevel node,
- an existing attribute inside a node or
- an existing value inside a list of values of an attribute.
It is an error
- to delete a toplevel node that doesn't exist or
- to delete an attribute that doesn't exist inside a node or
- to delete a non existing value from the list of values of an attribute.

Method 'set'
- replaces or adds a toplevel node or
- replaces or adds an attribute inside a node.

Parameters:

- path: Location that is to be changed. This is a comma separated list of names,
  starting with the name of some toplevel object.
- value: The value, given as JSON, that is to be inserted or removed.
- ok_if_exists: Optional boolean value, that suppresses the error message
  if an added toplevel object already exists.

All names in "path" correspond directly to names in
[Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html)
with these extensions:
1. Elements of group or pathrestriction are referenced by name 'elements'.
1. Rules of a services are referenced by name 'rules'.
1. An individual rule is referenced by its rule number (first index is 1).
1. A rule number may be given together with the total number of rules of a service as "2/3", meaning rule number 2 of 3. This is used as an additional check, that the rule number has not changed unexpectedly. A job aborts if expected and real number of rules differ.

When a new rule is added, no rule index is given,
because written order of rules doesn't matter.

If an attribute has a list of values e.g. "src=host:h1,host:h2,host:h3;"
the order also doesn't matter.
An existing value is accessed by value, not by index.
Example:

    { "method": "delete",
      "params": { "path": "service:s1,rules,1,src", "value": "host:h2" }
    }


More examples:

###### Add new network

    { "method": "add",
      "params": {
        "path": "network:n2",
        "value": { "ip": "10.1.2.0/24" }
      }
    }

##### Add VIP interface to existing router.

    { "method": "add",
      "params": {
        "path": "router:r1,interface:VIP",
        "value": {
            "ip": "10.1.2.0/24",
            "vip": null,
            "owner": "o1"
        }
      }
    }

##### Create service

    {
        "method": "add",
        "params": {
            "path": "service:s1",
            "value": {
                "description": "This one",
                "disable_at": "2099-12-31",
                "user": ["host:[network:n1] &! host:h4", "interface:r1.n1"],
                "rules": [
                    {
                        "action": "permit",
                        "src": "user",
                        "dst": ["network:n2", "host:h3"],
                        "prt": "tcp 80"
                    }
                ]
            }
        }
    }

##### Delete service

    {
        "method": "delete",
        "params": {
            "path": "service:s1"
        }
    }


##### Add to user of service

    {
        "method": "add",
        "params": {
            "path": "service:s1,user",
            "value": ["host:h4", "host:h6"]
        }
    }

##### Add to rule

Add host:h4 to destination of first rule of service:s2, but check,
that s2 has 3 rules.

    {
        "method": "add",
        "params": {
            "path": "service:s1,rules,1/3,dst",
            "value": "host:h4"
        }
    }

##### Add rule
    {
        "method": "add",
        "params": {
            "path": "service:s1,rules",
            "value": {
                "action": "permit",
                "src": "user",
                "dst": ["host:h5", "interface:r1.n2"],
                "prt": ["udp 123", "icmp"]
            }
        }
    }

##### Add element to group

    {
        "method": "add",
        "params": {
            "path": "group:g1,elements",
            "value": "host:h_10_1_2_7"
        }
    }

##### Delete element from group

    {
        "method": "delete",
        "params": {
            "path": "group:g1,elements",
            "value": "host:h_10_1_2_7"
        }
    }

##### Change elements of group

    {
        "method": "set",
        "params": {
            "path": "group:g1,elements",
            "value": [ "host:h_10_1_2_7", "network:n1" ]
        }
    }

##### Delete group

    {
        "method": "delete",
        "params": {
            "path": "group:g1"
        }
    }

##### Add new group

    {
        "method": "add",
        "params": {
            "path": "group:g1",
            "value": {
                "description": "Objects located in europe",
                "elements": [ "host:h_10_1_2_7", "network:n1" ]
            }
        }
    }

##### Replace attribute 'owner' of host
#### create_host

Add host to existing network.

Parameters:

- name: Name of host.
- ip: IP of host.
- owner: Optional owner of host.
- network: Name of network where new host is inserted.
- mask: Mask of network if name of network is ```[auto]```.

If name of network is ```[auto]```, the network will be searched by IP
address and mask.

#### modify_host

Modify existing host.

Parameters:

- name: Name of host.
- owner: Change or add owner of this host.

#### multi_job

Execute multiple jobs. Change is only applied, if all jobs succeed.

Parameter:

- jobs: Array of jobs.

### Deprecated methods

These methods are deprecated and should not be used by new projects.

#### create_owner

Add owner to file ```netspoc/owner```.

Parameters:

- name: Name of owner.
- admins: Array of admins.
- watchers: Array of watchers
- ok_if_exists: If this attribute is set and this owner already exists, this job is silently ignored, but counts as succeeded in multi_job.

#### modify_owner

Modify existing owner.

Parameters:

- name: Name of owner.
- admins: Array of admins.
- watchers: Array of watchers

If attribute already exists, the new value replaces the old one.
Use an empty array to remove existing value.
To change only one attribute, leave the other parameter unspecified.

#### delete_owner

Delete existing owner.

Parameters:

- name: Name of owner.

#### add_to_group

Add object to existing group.

Parameters:

- name: Name of group.
- object: [Object set in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#set-of-objects). Multiple values allowed.
