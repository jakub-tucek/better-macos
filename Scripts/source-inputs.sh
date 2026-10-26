#!/bin/bash
# Sourced from repository root by build.sh and test.sh. Preserve paths with spaces.
python3 scripts/generate-feature-index.py
APP_SOURCES=()
while IFS= read -r -d '' path; do APP_SOURCES+=("$path"); done < build/generated/app-sources.list
TEST_SOURCES=()
while IFS= read -r -d '' path; do TEST_SOURCES+=("$path"); done < build/generated/test-sources.list
APP_SOURCES+=(build/generated/BuiltinFeatureIndex.swift)
TEST_SOURCES+=(build/generated/RegisteredFeatureTests.swift)
