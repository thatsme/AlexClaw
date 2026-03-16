#!/bin/sh
set -e

echo "Running migrations..."
bin/alex_claw eval "AlexClaw.Release.migrate()"

echo "Checking for first-boot seeding..."
bin/alex_claw eval "AlexClaw.Release.seed_examples()"

echo "Starting AlexClaw..."
bin/alex_claw start
