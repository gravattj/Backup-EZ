#!/bin/sh

rm -rf blib *.gz MANIFEST
perl Makefile.PL && make && make test 
make clean && perl Makefile.PL && make manifest dist
