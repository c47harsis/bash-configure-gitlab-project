#!/bin/bash

API_RESPONSE_MESSAGE_REGEX='^{"message":"(.*)"}$'
API_RESPONSE_ERROR_REGEX='^{"error":"(.*)"}$'

function help() {
  echo ""
  echo "Usage: $0 [--help] [--token <private_token> ] [repo_url]"
  printf "%s\t\t%s\n" "--help" "Usage"
  printf "%s\t%s\n" "--token" "Your private access token"
  printf "%s\t\t%s\n" "[repo_url]" "URL of the repository"
  exit 1
}

# --- PARSE ARGUMENTS ---
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
  --help | \?) help ;;
  --token)
    PRIVATE_TOKEN="$2"
    shift
    shift
    ;;
  *)
    POSITIONAL+=("$1")
    shift
    ;;
  esac
done
set -- "${POSITIONAL[@]}"

REPO_URL="$1"

# --- / PARSE ARGUMENTS ---

if [[ -z $REPO_URL ]]; then
  read -r -p "Enter repository url: " REPO_URL;
fi

if [[ -z $PRIVATE_TOKEN ]]; then
  read -r -p "Enter your private token: " PRIVATE_TOKEN;
fi

REPO_REGEX="^(https?://)?([^/]+)/([^/].*[^/]).*$"

if [[ $REPO_URL =~ $REPO_REGEX ]]; then
  GITLAB_URL=${BASH_REMATCH[2]};
  REPO_NAME=${BASH_REMATCH[3]};
  echo "GitLab URL: $GITLAB_URL";
  echo "Repository name: $REPO_NAME";
else
  echo "Error: Invalid URL!";
  exit 1;
fi

REPO_NAME_URLENCODED=$(echo "$REPO_NAME" | sed 's/\//%2F/g')
API_URL="https://$GITLAB_URL/api/v4"

function print_message() {
  [[ $1 =~ $API_RESPONSE_MESSAGE_REGEX ]] && echo "Message: ${BASH_REMATCH[1]}"
  [[ $1 =~ $API_RESPONSE_ERROR_REGEX ]] && echo "Error: ${BASH_REMATCH[1]}"
}

function check_mainline() {
  RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$API_URL/projects/$REPO_NAME_URLENCODED/repository/branches/mainline2" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN")

  RESPONSE_STATUS=$(echo "$RESPONSE" | tail -n1)

  if [[ $RESPONSE_STATUS == 404 ]]; then
    echo "Repository doesn't contain mainline branch!";
    while true; do
        read -r -p "Do you wish to create it? (y/N): " yn
        case $yn in
            [Yy]* ) create_branch; break;;
            [Nn]* | "") echo "I was glad to see you anyway!"; exit;;
            * ) echo "Please type yes or no.";;
        esac
    done
  elif [[ $RESPONSE_STATUS -lt 200 || $RESPONSE_STATUS -gt 299 ]]; then
    echo "Error! Status: $RESPONSE_STATUS";
    exit 1;
  else
    echo "Branch mainline already exists!";
  fi
}

function create_branch() {
  read -r -p "Enter the branch name or commit SHA to create branch from: " BRANCH_FROM

  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "$API_URL/projects/$REPO_NAME_URLENCODED/repository/branches?branch=mainline2&ref=$BRANCH_FROM" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN")

  RESPONSE_STATUS=$(echo "$RESPONSE" | tail -n1)
  RESPONSE_BODY=$(echo "$RESPONSE" | sed '$ d')

  if [[ $RESPONSE_STATUS == 201 ]]; then
    echo "Branch mainline successfully created from $BRANCH_FROM";
  else
    echo "Error when creating the branch!";
    print_message "$RESPONSE_BODY";
    exit 1;
  fi
}

function protect_mainline() {
  echo "Docs: https://docs.gitlab.com/ee/api/branches.html#protect-repository-branch"
  echo "Trying to unprotect firstly..."
  curl -s -X DELETE \
  "$API_URL/projects/$REPO_NAME_URLENCODED/protected_branches/mainline" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN"

  echo "Protecting mainline branch..."
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "$API_URL/projects/$REPO_NAME_URLENCODED/protected_branches?name=mainline&push_access_level=40&merge_access_level=30&unprotect_access_level=40&code_owner_approval_required=true" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN")

  RESPONSE_STATUS=$(echo "$RESPONSE" | tail -n1)
  RESPONSE_BODY=$(echo "$RESPONSE" | sed '$ d')

  if [[ $RESPONSE_STATUS -gt 199 && $RESPONSE_STATUS -lt 300 ]]; then
    echo "Protected successfully!";
  else
    echo "Error when protecting mainline branch!";
    print_message "$RESPONSE_BODY";
    exit 1;
  fi
}

function apply_settings() {
  echo "Docs: https://docs.gitlab.com/ee/api/projects.html#edit-project"
  echo "Applying settings from project_settings.json..."
  echo "Settings to apply:"
  cat project_settings.json

  RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
  "$API_URL/projects/$REPO_NAME_URLENCODED" \
  -H "Content-Type: application/json" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
  -d '@project_settings.json')

  RESPONSE_STATUS=$(echo "$RESPONSE" | tail -n1)
  RESPONSE_BODY=$(echo "$RESPONSE" | sed '$ d')

  if [[ $RESPONSE_STATUS -lt 200 || $RESPONSE_STATUS -gt 299 ]]; then
    print_message "$RESPONSE_BODY";
    exit 1;
  else
    echo "Applied successfully!";
  fi
}

function apply_merge_request() {
  echo "Docs: https://docs.gitlab.com/ee/api/merge_request_approvals.html"
  echo "Applying settings from merge_settings.json..."
  echo "Settings to apply:"
  cat merge_settings.json

  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "$API_URL/projects/$REPO_NAME_URLENCODED/approvals" \
  -H "Content-Type: application/json" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
  -d '@merge_settings.json')

  RESPONSE_STATUS=$(echo "$RESPONSE" | tail -n1)
  RESPONSE_BODY=$(echo "$RESPONSE" | sed '$ d')

  if [[ $RESPONSE_STATUS -lt 200 || $RESPONSE_STATUS -gt 299 ]]; then
    print_message "$RESPONSE_BODY";
    exit 1;
  else
    echo "Applied successfully!";
  fi
}

echo ""
echo "--- STAGE 1: Make sure mainline exists"
check_mainline
echo ""
echo "--- STAGE 2: Protect mainline"
protect_mainline
echo ""
echo "--- STAGE 3: Configure project settings"
apply_settings
echo ""
echo "--- STAGE 4: Configure merge request approvals settings"
apply_merge_request
echo ""
echo "--- STAGE 5: Congrats!"