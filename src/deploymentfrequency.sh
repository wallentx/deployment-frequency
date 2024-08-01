#!/usr/bin/env bash

# Function to display usage information
usage() {
    echo "Usage: $0 -o ownerRepo -w workflows -b branch -n numberOfDays [-p patToken] [-a actionsToken] [-i appId] [-I appInstallationId] [-k appPrivateKey]"
    echo ""
    echo "  -o  ownerRepo           The owner and repository in the format owner/repo"
    echo "  -w  workflows           Comma-separated list of workflow names"
    echo "  -b  branch              Branch name"
    echo "  -n  numberOfDays        Number of days to look back"
    echo "  -p  patToken            Personal Access Token (optional)"
    echo "  -a  actionsToken        GitHub Actions Token (optional)"
    echo "  -i  appId               GitHub App ID (optional)"
    echo "  -I  appInstallationId   GitHub App Installation ID (optional)"
    echo "  -k  appPrivateKey       GitHub App Private Key (optional)"
    echo "  -v                      Enable debug (optional)"
    exit 1
}

# Main function
main() {
    local ownerRepo="$1"
    local workflows="$2"
    local branch="$3"
    local numberOfDays="$4"
    local patToken="$5"
    local actionsToken="$6"
    local appId="$7"
    local appInstallationId="$8"
    local appPrivateKey="$9"

    IFS='/' read -r owner repo <<< "$ownerRepo"
    IFS=',' read -r -a workflowsArray <<< "$workflows"

    echo "Owner/Repo: $owner/$repo"
    echo "Workflows: $workflows"
    echo "Branch: $branch"
    echo "Number of days: $numberOfDays"

    if [[ -n "$patToken" ]]; then
        export GH_TOKEN="$patToken"
    elif [[ -n "$actionsToken" ]]; then
        export GH_TOKEN="$actionsToken"
    fi

    workflowsResponse=$(gh api "repos/$owner/$repo/actions/workflows" -q '.workflows')

    if [[ -z "$workflowsResponse" ]]; then
        echo "Repo is not found or you do not have access"
        exit 1
    fi

    workflowIds=()
    workflowNames=()
    for workflow in $(echo "$workflowsResponse" | jq -r '.[] | @base64'); do
        workflow=$(echo "$workflow" | base64 --decode)
        workflow_name=$(echo "$workflow" | jq -r '.name')
        workflow_id=$(echo "$workflow" | jq -r '.id')

        for arrayItem in "${workflowsArray[@]}"; do
            if [[ "$workflow_name" == "$arrayItem" ]]; then
                if ! [[ " ${workflowIds[*]} " =~ $workflow_id ]]; then
                    workflowIds+=("$workflow_id")
                fi
                if ! [[ " ${workflowNames[*]} " =~ $workflow_name ]]; then
                    workflowNames+=("$workflow_name")
                fi
            fi
        done
    done

    dateList=()
    uniqueDates=()
    deploymentsPerDayList=()

    for workflowId in "${workflowIds[@]}"; do
        workflowRunsResponse=$(gh api "repos/$owner/$repo/actions/workflows/$workflowId/runs?per_page=100&status=completed" -q '.workflow_runs')

        for run in $(echo "$workflowRunsResponse" | jq -r '.[] | @base64'); do
            run=$(echo "$run" | base64 --decode)
            run_branch=$(echo "$run" | jq -r '.head_branch')
            run_created_at=$(echo "$run" | jq -r '.created_at')
            run_created_at_epoch=$(date -d "$run_created_at" +%s)
            run_cutoff_epoch=$(date -d "$numberOfDays days ago" +%s)

            if [[ "$run_branch" == "$branch" && "$run_created_at_epoch" -gt "$run_cutoff_epoch" ]]; then
                dateList+=("$(echo "$run" | jq -r '.created_at')")
                uniqueDates+=("$(date -d "$run_created_at" +%Y-%m-%d)")
            fi
        done

        if [[ "${#dateList[@]}" -gt 0 ]]; then
            deploymentsPerDay=$(echo "scale=2; ${#dateList[@]} / $numberOfDays" | bc)
            deploymentsPerDayList+=("$deploymentsPerDay")
        fi
    done

    totalDeployments=0
    for deployment in "${deploymentsPerDayList[@]}"; do
        totalDeployments=$(echo "$totalDeployments + $deployment" | bc)
    done

    if [[ "${#deploymentsPerDayList[@]}" -gt 0 ]]; then
        deploymentsPerDay=$(echo "scale=2; $totalDeployments / ${#deploymentsPerDayList[@]}" | bc)
    fi

    rateLimitResponse=$(gh api "rate_limit" -q '.rate')
    rate_used=$(echo "$rateLimitResponse" | jq -r '.used')
    rate_limit=$(echo "$rateLimitResponse" | jq -r '.limit')
    echo "Rate limit consumption: $rate_used / $rate_limit"

    mapfile -t uniqueDates < <(printf "%s\n" "${uniqueDates[@]}" | sort -u)

    rating="None"
    color="lightgrey"
    displayMetric=0
    displayUnit="per day"

    dailyDeployment=1
    weeklyDeployment=$(echo "scale=2; 1 / 7" | bc)
    monthlyDeployment=$(echo "scale=2; 1 / 30" | bc)
    yearlyDeployment=$(echo "scale=2; 1 / 365" | bc)

    if (( $(echo "$deploymentsPerDay > $dailyDeployment" | bc -l) )); then
        rating="Elite"
        color="brightgreen"
        displayMetric=$(echo "scale=2; $deploymentsPerDay" | bc)
        displayUnit="per day"
    elif (( $(echo "$deploymentsPerDay >= $weeklyDeployment && $deploymentsPerDay <= $dailyDeployment" | bc -l) )); then
        rating="High"
        color="green"
        displayMetric=$(echo "scale=2; $deploymentsPerDay * 7" | bc)
        displayUnit="times per week"
    elif (( $(echo "$deploymentsPerDay >= $monthlyDeployment && $deploymentsPerDay < $weeklyDeployment" | bc -l) )); then
        rating="Medium"
        color="yellow"
        displayMetric=$(echo "scale=2; $deploymentsPerDay * 30" | bc)
        displayUnit="times per month"
    elif (( $(echo "$deploymentsPerDay > $yearlyDeployment && $deploymentsPerDay < $monthlyDeployment" | bc -l) )); then
        rating="Low"
        color="red"
        displayMetric=$(echo "scale=2; $deploymentsPerDay * 30" | bc)
        displayUnit="times per month"
    elif (( $(echo "$deploymentsPerDay <= $yearlyDeployment" | bc -l) )); then
        rating="Low"
        color="red"
        displayMetric=$(echo "scale=2; $deploymentsPerDay * 365" | bc)
        displayUnit="times per year"
    fi

    if (( ${#dateList[@]} > 0 && numberOfDays > 0 )); then
        echo "Deployment frequency over last $numberOfDays days, is $displayMetric $displayUnit, with a DORA rating of '$rating'"
        get_formatted_markdown "${workflowNames[@]}" "$rating" "$displayMetric" "$displayUnit" "$ownerRepo" "$branch" "$numberOfDays" "${#uniqueDates[@]}" "$color"
    else
        get_formatted_markdown_no_result "$workflows" "$numberOfDays"
    fi
}

# Function to get formatted markdown
get_formatted_markdown() {
    local workflowNames=("$1")
    local rating="$2"
    local displayMetric="$3"
    local displayUnit="$4"
    local repo="$5"
    local branch="$6"
    local numberOfDays="$7"
    local numberOfUniqueDates="$8"
    local color="$9"

    local encodedString
    encodedString=$(echo -n "$displayMetric $displayUnit" | jq -sRr @uri)

    echo -e "\n\n![Deployment Frequency](https://img.shields.io/badge/frequency-$encodedString-$color?logo=github&label=Deployment%20frequency)\n" \
    "**Definition:** For the primary application or service, how often is it successfully deployed to production.\n" \
    "**Results:** Deployment frequency is **$displayMetric $displayUnit** with a **$rating** rating, over the last **$numberOfDays days**.\n" \
    "**Details**:\n" \
    "- Repository: $repo using $branch branch\n" \
    "- Workflow(s) used: ${workflowNames[*]}\n" \
    "- Active days of deployment: $numberOfUniqueDates days\n" \
    "---"
}

# Function to get formatted markdown for no result
get_formatted_markdown_no_result() {
    local workflows="$1"
    local numberOfDays="$2"

    echo -e "\n\n![Deployment Frequency](https://img.shields.io/badge/frequency-none-lightgrey?logo=github&label=Deployment%20frequency)\n\n" \
    "No data to display for $ownerRepo for workflow(s) $workflows over the last $numberOfDays days\n\n" \
    "---"
}

# Parse command-line options
while getopts ":o:w:b:n:p:a:i:I:k:hv" opt; do
    case ${opt} in
        o )
            ownerRepo=$OPTARG
            ;;
        w )
            workflows=$OPTARG
            ;;
        b )
            branch=$OPTARG
            ;;
        n )
            numberOfDays=$OPTARG
            ;;
        p )
            patToken=$OPTARG
            ;;
        a )
            actionsToken=$OPTARG
            ;;
        i )
            appId=$OPTARG
            ;;
        I )
            appInstallationId=$OPTARG
            ;;
        k )
            appPrivateKey=$OPTARG
            ;;
        h )
            usage
            ;;
        v )
            set -x
            ;;
        \? )
            echo "Invalid option: -$OPTARG" 1>&2
            usage
            ;;
        : )
            echo "Invalid option: -$OPTARG requires an argument" 1>&2
            usage
            ;;
    esac
done

# Check required parameters
if [ -z "$ownerRepo" ] || [ -z "$workflows" ] || [ -z "$branch" ] || [ -z "$numberOfDays" ]; then
    echo "Missing required parameters" 1>&2
    usage
fi

# Shift off the options and optional --
shift $((OPTIND -1))

# Script entry point
main "$ownerRepo" "$workflows" "$branch" "$numberOfDays" "$patToken" "$actionsToken" "$appId" "$appInstallationId" "$appPrivateKey"
