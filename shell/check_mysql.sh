#!/bin/bash
if ! mysqladmin -uroot -p"123456" ping >/dev/null; then
  exit 1
fi
exit 0