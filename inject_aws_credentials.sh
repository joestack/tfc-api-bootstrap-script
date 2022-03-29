#!/bin/bash

source environment.conf

doormat aws -r $doormat_arn --tf-push --tf-organization $organization --tf-workspace $workspace

