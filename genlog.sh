#!/bin/bash

## NOTE: This requires git version 2.22.0

RELEASE=$1
shift; 

COMMIT_PATH="-/commit"
ISSUE_PATH="-/issues"
NOTES_PATH="NOTES.md"
MR_FILE="mreq.json"
PROJECT_PATH=""
SERVER_URL=""

while getopts ":c:i:m:n:p:s:t:v" flag; do
    case "$flag" in
        c) COMMIT_PATH=${OPTARG};;
        i) ISSUE_PATH=${OPTARG};;
        m) MR_FILE=${OPTARG};;
        n) NOTES_PATH=${OPTARG};;
        p) PROJECT_PATH=${OPTARG};;
        s) SERVER_URL=${OPTARG};;
        t) AFTER_TAG=${OPTARG};;
        v) VERBOSE="true";;
        ?) echo "Invalid option: -${OPTARG}";;
    esac
done

if [[ $RELEASE != "patch" && $RELEASE != "minor" && $RELEASE != "major" ]]; then
    echo "Argument must be one of: [ major, minor, patch ]";
    exit 1;
fi

if [[ -n $AFTER_TAG ]]; then
    ## Check if valid semvar tag given
    if [[ ! $AFTER_TAG =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo "Invalid tag given for -t, must be valid semvar: MAJOR.MINOR.PATCH";
        exit 1;
    fi
    CURVER=$AFTER_TAG
else
    DOCKER_SERVICE_NAME="main:"
    PROD_IMAGE=$(awk "/${DOCKER_SERVICE_NAME}/{getline; print; exit;}" $PWD/docker-compose.yml)
    CURVER=$(echo $PROD_IMAGE | cut -d ":" -f3 | cut -d "-" -f1)
fi


MAJOR=$(echo $CURVER | cut -d "." -f 1)
MINOR=$(echo $CURVER | cut -d "." -f 2)
PATCH=$(echo $CURVER | cut -d "." -f 3)
NEXT_MAJOR=$(($MAJOR + 1))
NEXT_MINOR=$(($MINOR + 1))
NEXT_PATCH=$(($PATCH + 1))


[[ $RELEASE == 'major' ]] && VERSION=${NEXT_MAJOR}.0.0
[[ $RELEASE == 'minor' ]] && VERSION=${MAJOR}.${NEXT_MINOR}.0
[[ $RELEASE == 'patch' ]] && VERSION=${MAJOR}.${MINOR}.${NEXT_PATCH}


TODAY=$(date +"%F")
TMP_GITLOG_FILE="commits.txt"

COMMITS_AFTER=$CURVER

##! Check if current docker-compose semvar works
git log ${COMMITS_AFTER}.. > /dev/null 2>&1
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
    ##! Check for last known git tag
    COMMITS_AFTER=$(git describe --abbrev=0 --tags)
    EXIT_CODE=$?
    if [[ $EXIT_CODE -ne 0 ]]; then
        ##! If no known tags, use first commit
        COMMITS_AFTER=$(git rev-list --max-parents=0 HEAD)
        ## Another method
        #COMMITS_AFTER=$(git log --oneline --format="%h" | tail -1)
    fi
fi

[[ -n $VERBOSE ]] && echo "Getting commits with changelog trailers since $COMMITS_AFTER"

ISSUE_TRAILER_KEYS="key=Issue,key=Closes,key=Close,key=Fix,key=Fixes,key=Related,key=Addresses"
ISSUE_TRAILER="%(trailers:$ISSUE_TRAILER_KEYS,valueonly,separator=%x2C )"
CREDIT_TRAILER="%(trailers:key=Credit,valueonly,separator=%x2C )"
CHANGELOG_TRAILER="%(trailers:key=Changelog,valueonly,separator=%x2C )"

git log ${COMMITS_AFTER}.. --format="- [ %h ] **\`${CHANGELOG_TRAILER}\`** - %s $ISSUE_TRAILER ($CREDIT_TRAILER)  " --date=short \
    | grep "\*\*\`[: ,[:alpha:]]\+\`\*\*" \
    | sort -k 5,5 -d -f -s > $TMP_GITLOG_FILE

NUM_TRAILER_COMMITS=$(cat $TMP_GITLOG_FILE | wc -l)

if [[ $NUM_TRAILER_COMMITS -eq 0 ]]; then
    echo "No new changelog trailers found, aborting CHANGELOG.md update"
    rm $TMP_GITLOG_FILE
    exit 0;
fi

##! Remove empty/extra
sed -i "s/()//g" $TMP_GITLOG_FILE
sed -i "s/ *changelog://Ig" $TMP_GITLOG_FILE
sed -i "s/  *$/  /g" $TMP_GITLOG_FILE

##! Given a merge_request JSON file formatted with a minimum [{sha: SHA, reference: REF, web_url: MR_URL}, ...]
##! Add merge requests links to commits that have a Credit trailer
if [[ -f $MR_FILE ]]; then
    while read LINE; do
        HAS_CREDIT=$(echo $LINE | grep "(.*) *$")
        [[ -z $HAS_CREDIT ]] && continue
        SHA=$(echo $LINE | cut -d " " -f3)
        MR=( $(jq -r '.[] | select(.sha | match("^'$SHA'")) | .reference, .web_url ' $MR_FILE) )
        [[ -n $MR ]] && sed -i "/- \[ $SHA \]/ s|$| \[${MR[0]}\]\(${MR[1]}\)|" $TMP_GITLOG_FILE
    done <$TMP_GITLOG_FILE
fi

##! Replace wth links only if server url and project path given
if [[ -n $SERVER_URL && -n $PROJECT_PATH ]]; then
    ##! Replace issues -   #num & namespace/project/#num
    sed -i -r "s| #([0-9]*)| \[#\1\]\($SERVER_URL/$PROJECT_PATH/$ISSUE_PATH/\1\)|g" $TMP_GITLOG_FILE
    #TODO: Ensure accomodating all project characters, currently:   0-9a-Z/-.
    sed -i -r "s| ([-/[:alnum:]\.]+)#([0-9]*)| \[\1#\2\]\($SERVER_URL/\1/$ISSUE_PATH/\2\)|g" $TMP_GITLOG_FILE

    ##! Replace commits 
    sed -i -r "s|- \[ ([[:alnum:]]*) \]|- \[ \[\1\]\($SERVER_URL/$PROJECT_PATH/$COMMIT_PATH/\1\) \]|g" $TMP_GITLOG_FILE
    #exit
fi

CATEGORY_ORDER=( Massive Added Fixed Deprecated Removed Changed Security Performance Other )

for CATEGORY in "${CATEGORY_ORDER[@]}"; do
    COUNT=$(sed -n "/\*\*\`$CATEGORY.*\`\*\*/Ip" $TMP_GITLOG_FILE | wc -l)
    START=$(sed -n "/\*\*\`$CATEGORY.*\`\*\*/I=" $TMP_GITLOG_FILE | head -1)
    if [[ $COUNT -gt 0 ]]; then
        [[ -n $VERBOSE ]] && echo "Found $COUNT '$CATEGORY' commit(s)"
        sed -i "s/\*\*\`.*$CATEGORY.*\`\*\*/\L&/I" $TMP_GITLOG_FILE
        sed -i "${START}i \\\n#### **$CATEGORY ($COUNT)**" $TMP_GITLOG_FILE
    fi
done

#cat $TMP_GITLOG_FILE 
#exit

SPLIT_PREFIX="xx"
csplit -sz -f $SPLIT_PREFIX --suppress-matched $TMP_GITLOG_FILE /^$/ {*}
FILES=( `ls ${SPLIT_PREFIX}*` )

#rm ${FILES[@]}
#rm $TMP_GITLOG_FILE
#exit

[[ -n $VERBOSE ]] && echo "Creating $VERSION changelog for commits after $COMMITS_AFTER"

echo "" > CHANGES.md
printf "%s\n\n" "# $VERSION - (*$TODAY*)" >> CHANGES.md

if [[ -f $NOTES_PATH ]]; then
    [[ -n $VERBOSE ]] && echo "Adding $NOTES_PATH from given -n \$NOTES_PATH"
    printf "%s\n" "### Notable changes  " >> CHANGES.md
    cat $NOTES_PATH >> CHANGES.md
    echo >> CHANGES.md
    echo "<br>" >> CHANGES.md
    echo >> CHANGES.md
fi

[[ -n $VERBOSE ]] && echo "Adding formatted changelog commits"

for CATEGORY in "${CATEGORY_ORDER[@]}"; do
    for FILE in "${FILES[@]}"; do
        if [[ `sed -n "1p" $FILE` =~ ${CATEGORY} ]]; then
            cat $FILE >> CHANGES.md
            echo "" >> CHANGES.md
            break;
        fi
    done
done

rm ${FILES[@]}
rm $TMP_GITLOG_FILE
#exit

if [[ -f CHANGELOG.md ]]; then
    [[ -n $VERBOSE ]] && echo "Appending previous CHANGELOG.md"
    echo "<br><br><br>" >> CHANGES.md
    cat CHANGELOG.md >> CHANGES.md
fi

#exit

mv CHANGES.md CHANGELOG.md

