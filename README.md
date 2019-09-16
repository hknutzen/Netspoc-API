
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
  * [multi_job](#multi_job)


### Asynchronous processing

Netspoc-API processes jobs asyncronously. After posting a job to
```http:SERVER/add-job``` the server returns a job-id as JSON:
```{ "id" : <job-id> }```.

The status of a job is requested by posting ```{ "id" : <job-id> }``` to
```http:SERVER/job-status```.
This results in JSON data with attribute ```status``` and optional
```msg```.

Status is one of:

- WAITING, job is waiting in queue.
- INPROGRESS, processing of job has started.
- FINISHED, processing of job has finished without errors.
- ERROR, job has finished with errors; no changes have been made.
         The error message can be found in attribute ```msg```.
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
address and mask. The job aborts if no or multiple networks with this IP/mask are found.

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
- object: Typed name of object that is added.

#### multi_job

Execute multiple jobs. Change is only applied, if all jobs succeed.

Parameter:

- jobs: Array of jobs.