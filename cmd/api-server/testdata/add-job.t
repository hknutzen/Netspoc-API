=TEMPL=config
--config
{"user": {
  "u1": {
    "hash": "$2a$04$Y9E/EE0BJd4ABTLgRTR0I.bgjmQAYuj9jXVHUL1t9fewKk8IATVWS"
  }
 }
}
=END=

=TITLE=Initialize counter
=INPUT=
[[config]]
=URL=/add-job
=REQUEST={"user": "u1", "pass": "secret"}
=OUTPUT=
--job-counter
1
--waiting/1
{"user": "u1"}
=RESPONSE={"id": "1"}
=STATUS=200

=TITLE=Increment counter
=INPUT=
[[config]]
--job-counter
999
=URL=/add-job
=REQUEST={"user": "u1", "pass": "secret"}
=OUTPUT=
--job-counter
1000
--waiting/1000
{"user": "u1"}
=RESPONSE={"id": "1000"}
=STATUS=200

=TITLE=Overwrite job with same id
=INPUT=
[[config]]
--job-counter
1
--waiting/2
{"a": "bc"}
=URL=/add-job
=REQUEST={"user": "u1", "pass": "secret"}
=OUTPUT=
--job-counter
2
--waiting/2
{"user": "u1"}
=RESPONSE={"id": "2"}
=STATUS=200
