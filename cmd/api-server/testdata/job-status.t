=TEMPL=config
--config
{"user": {
  "u1": {
    "hash": "$2a$04$Y9E/EE0BJd4ABTLgRTR0I.bgjmQAYuj9jXVHUL1t9fewKk8IATVWS"
  }
 }
}
=END=

=TITLE=Waiting
=INPUT=
[[config]]
--waiting/42
{}
=URL=/job-status
=REQUEST={"user": "u1", "pass": "secret", "id": "42"}
=RESPONSE={"status": "WAITING"}
=STATUS=200

=TITLE=In progress
=INPUT=
[[config]]
--inprogress/42
{}
=URL=/job-status
=REQUEST={"user": "u1", "pass": "secret", "id": "42"}
=RESPONSE={"status": "INPROGRESS"}
=STATUS=200

=TITLE=Finished
=INPUT=
[[config]]
--finished/42
{"user": "u1"}
--result/42
=URL=/job-status
=REQUEST={"user": "u1", "pass": "secret", "id": "42"}
=RESPONSE={"status": "FINISHED"}
=STATUS=200

=TITLE=Finished, missinng result
=INPUT=
[[config]]
--finished/42
{"user": "u1"}
=URL=/job-status
=REQUEST={"user": "u1", "pass": "secret", "id": "42"}
=RESPONSE=
open result/42: no such file or directory
=STATUS=500

=TITLE=Finished, bad job
=INPUT=
[[config]]
--finished/42
BAD
=URL=/job-status
=REQUEST={"user": "u1", "pass": "secret", "id": "42"}
=RESPONSE=
Job has invalid JSON: invalid character 'B' looking for beginning of value
=STATUS=500

=TITLE=Denied, other user
=INPUT=
[[config]]
--finished/42
{"user": "u2"}
=URL=/job-status
=REQUEST={"user": "u1", "pass": "secret", "id": "42"}
=RESPONSE=
{"status": "DENIED"}
=STATUS=200

=TITLE=Finished, try again
=INPUT=
[[config]]
--finished/42
{"user": "u1"}
--result/42
API is currently unusable, because someone else has checked in bad files.
 Please try again later.
=URL=/job-status
=REQUEST={"user": "u1", "pass": "secret", "id": "42"}
=RESPONSE=
API is currently unusable, because someone else has checked in bad files.
 Please try again later.
=STATUS=500

=TITLE=Finished with errors
=INPUT=
[[config]]
--finished/42
{"user": "u1"}
--result/42
Error: Can't resolve network:n1 in user of service:s1
=URL=/job-status
=REQUEST={"user": "u1", "pass": "secret", "id": "42"}
=RESPONSE=
{"status": "ERROR",
 "message": "Error: Can't resolve network:n1 in user of service:s1\n"
}
=STATUS=200

=TITLE=Unknown
=INPUT=
[[config]]
=URL=/job-status
=REQUEST={"user": "u1", "pass": "secret", "id": "42"}
=RESPONSE={"status": "UNKNOWN"}
=STATUS=200
