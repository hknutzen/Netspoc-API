
## Netspoc-API

Netspoc-API is a web service to automatically change text files of a
Netspoc configuration.

---

* [Asynchronous processing](#asynchronous-processing)
* [Authentication](#authentication)
* [Jobs](#jobs)
  * [create_host](#create_host)
  * [modify_host](#modify_host)
  * [create_owner](#create_owner)
  * [modify_owner](#modify_owner)
  * [delete_owner](#delete_owner)
  * [add_to_group](#add_to_group)
  * [create_service](#create_service)
  * [delete_service](#delete_service)
  * [add_to_user](#add_to_user)
  * [remove_from_user](#remove_from_user)
  * [add_to_rule](#add_to_rule)
  * [remove_from_rule](#remove_from_rule)
  * [add_rule](#add_rule)
  * [delete_rule](#delete_rule)
  * [multi_job](#multi_job)


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

#### create_service

Create service with user and rules.
Service is inserted in file ```netspoc/rule/X```,
where 'X' is first letter of service name converted to upper case.
This applies to alphanumeric letter. Otherwise file ```netspoc/rule/other``` is used.

Parameters:

- name: Name of service.
- description: Optional description text.
- user: [Object set in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#set-of-objects).
- rules: Array of JSON objects defining rules:
  - action: One of "permit" or "deny".
  - src: String with [object set with 'user' in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#service-definition).
  - dst: Like 'src'. One of 'src' and 'dst' must reference 'user'.
  - prt: [List of protocols in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#groups-of-protocols).

#### delete_service

Delete existing service.

Parameters:

- name: Name of service.

#### add_to_user

Add objects to user list of existing service.

Parameters:

- service: Name of service.
- user: [Object set in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#set-of-objects). Multiple values allowed.

#### remove_from_user

Remove objects from user list of existing service.

Parameters:

- service: Name of service.
- user: [Object set in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#set-of-objects). Multiple values allowed.

#### add_to_rule

Add to src, dst or prt in rule of existing service.

Parameters:

- service: Name of service.
- rule_num: Number of rule that will be changed. Rules count from 1.
- src: [Object set with 'user' in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#service-definition). Multiple values allowed.
- dst: Like 'src'.
- prt: [List of protocols in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#groups-of-protocols).

#### remove_from_rule

Remove from src, dst or prt in rule of existing service.

Parameters:

- service: Name of service.
- rule_num: Number of rule that will be changed.
- src: [Object set with 'user' in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#service-definition). Multiple values allowed.
- dst: Like 'src'.
- prt: [List of protocols in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#groups-of-protocols).

#### add_rule

Add rule to existing service.
Permit rule is appended at end of existing rules.
Deny rule is added after last deny rule if one exists or as first
rule otherwise.

Parameters:

- service: Name of service.
- action: One of "permit" or "deny".
- src: [Object set with 'user' in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#service-definition). Multiple values allowed.
- dst: Like 'src'. One of 'src' and 'dst' must reference 'user'.
- prt: [List of protocols in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#groups-of-protocols).

#### delete_rule

Delete rule from existing service.

Parameters:

- service: Name of service.
- rule_num: Number of rule that will be deleted.

#### create_toplevel

Create new toplevel object.

Parameters:

- definition: [Definition of toplevel object in Netspoc syntax](http://hknutzen.github.io/Netspoc/syntax.html#netspoc-configuration).
- file: Name of file, where object is inserted. Name is given relative to directory of netspoc files.
- ok_if_exists: If this attribute is set and this object already exists, this job is silently ignored, but counts as succeeded in multi_job.

#### delete_toplevel

- name: Name of object.

#### multi_job

Execute multiple jobs. Change is only applied, if all jobs succeed.

Parameter:

- jobs: Array of jobs.