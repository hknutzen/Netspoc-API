
=TITLE=Bad request
=INPUT=
--config
{}
=URL=/add-job
=REQUEST=NO JSON
=RESPONSE=
Invalid JSON: invalid character 'N' looking for beginning of value
=STATUS=400

=TITLE=Missing user
=INPUT=
--config
{}
=URL=/add-job
=REQUEST={}
=RESPONSE=
Missing 'user'
=STATUS=400

=TITLE=Missing password
=INPUT=
--config
{}
=URL=/add-job
=REQUEST={"user": "u1"}
=RESPONSE=
Missing 'pass'
=STATUS=400

=TITLE=Unauthorized user
=INPUT=
--config
{}
=URL=/add-job
=REQUEST={"user": "u1", "pass": "secret"}
=RESPONSE=
User is not authorized
=STATUS=400

=TITLE=Authorized user, no authentication method configured
=INPUT=
--config
{"user": {
  "u1": {}
 }
}
=URL=/add-job
=REQUEST={"user": "u1", "pass": "secret"}
=RESPONSE=
No authentication method configured
=STATUS=500

=TITLE=Authorized user, bad URL
=INPUT=
--config
{"user": {
  "u1": {
    "hash": "$2a$04$Y9E/EE0BJd4ABTLgRTR0I.bgjmQAYuj9jXVHUL1t9fewKk8IATVWS"
  }
 }
}
=URL=/bad-url
=REQUEST={"user": "u1", "pass": "secret"}
=RESPONSE=
Unknown path
=STATUS=400
