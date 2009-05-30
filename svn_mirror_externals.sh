#!/bin/bash
GIT_DIR=${GIT_DIR:-.git}
WORK_DIR=$GIT_DIR/mirror-externals

# git-svn find-rev is painfully slow
find_rev() {
   local arg=$1
   local cache=${WORK_DIR}/rev-cache/$arg
   cat $cache 2>/dev/null && return 0
   git svn find-rev $arg | tee $cache
   # cache the backreference too
   echo ${arg#r} > ${WORK_DIR}/rev-cache/$(cat $cache)
}

index_filter() {
    [ -z "$URL_BASE" ] && echo "URL_BASE not set" && exit 1

    # Find the SVN revision for this commit
    SVN_REV=$(find_rev $GIT_COMMIT)
    #echo
    #echo "    Processing externals for r$SVN_REV"


    #Walk the unhandled properties log to determine externals to apply.
    export STOP_REV=$SVN_REV
    export WORK_DIR
    rm -rf $WORK_DIR/tmp
    mkdir -p $WORK_DIR/{tmp,rev-cache,ls-tree}
    cat "$GIT_DIR/svn/git-svn/unhandled.log" | perl -e '
    $WORK_DIR=$ENV{"WORK_DIR"};
    while(<>) {
        if(m/^r([0-9]+)$/) {
            $rev=$1;
            last if($rev > $ENV{"STOP_REV"});
        } elsif(m/ *\+dir_prop: (.*) svn:externals (.*)$/) {
            $dir=$1;        
	    $m = $2;

	    while($m =~ /%([0-9a-f]{2})/gi) {
	        substr($m,pos($m)-3,3)=chr(hex($1));
	    }
	    system("mkdir","-p","$WORK_DIR/tmp/$dir");
	    open(EXT,">$WORK_DIR/tmp/$dir/externals");
	    print EXT $m;
        }
    }
    '

    # Apply the externals
    for dir in `find $WORK_DIR/tmp -name externals`; do
        dir=${dir#${WORK_DIR}/tmp/}
        dir=$(dirname $dir) #${dir%/externals}
        #echo "    applying externals to $dir"
        while read subdir pinrev url; do
            [ -z "$subdir" ] && continue
            if [ -z "$url" ]; then
                url=$pinrev
                pinrev="-r$SVN_REV"
            fi
            subdir="$dir/$subdir"
            subdir=${subdir#./}
            src_path=${url#${URL_BASE}}
            src_path=${src_path#/}

            [ -f $WORK_DIR/ls-tree/$pinrev/tree ] || {
              mkdir -p $WORK_DIR/ls-tree/$pinrev
              git ls-tree -r $(find_rev ${pinrev#-}) \
                > $WORK_DIR/ls-tree/$pinrev/tree
            }

            [ -f $WORK_DIR/ls-tree/$pinrev/$src_path/grep ] || {
              mkdir -p $WORK_DIR/ls-tree/$pinrev/$src_path
              grep $'\t'"$src_path" $WORK_DIR/ls-tree/$pinrev/tree \
                > $WORK_DIR/ls-tree/$pinrev/$src_path/grep
            }

            sed "s;\t$src_path;\t$subdir;g" \
              < $WORK_DIR/ls-tree/$pinrev/$src_path/grep
        done < ${WORK_DIR}/tmp/$dir/externals
    done  | git update-index --index-info
    rm -rf $WORK_DIR/ls-tree/-r$SVN_REV
}


do_apply() {
    echo "*"
    echo "* Applying externals"
    echo "*"
    [ -z "$URL_BASE" ] && export URL_BASE=$(git config svn-remote.svn.url)
    git branch apply-externals git-svn 2>/dev/null
    git filter-branch --index-filter $(cd $WORK_DIR && pwd)/index-filter \
        -- apply-externals   
}


do_rearrange() {
    #branches=`find $GIT_DIR/refs/heads -type f |
    #          grep -e 'trunk|branches|tags' |
    #          sed -e "s;^$GIT_DIR/refs/heads/;;g"`
    echo "*"
    echo "* Rearranging svn projects to git heads"
    echo "*" 
    branches=`git ls-tree -r -t git-svn \
              | egrep '/trunk$|/(branches|tags)/[^/]+$' \
              | sed -e 's/^.*\t//'`
    for b in $branches; do
        git branch -D $b 2>/dev/null
        git branch $b apply-externals
        git filter-branch --original /dev/null --subdirectory-filter $b -- $b
    done
}


do_reparent() {
    echo "*"
    echo "* Reparenting head root nodes"
    echo "*"
    # want branches in date order
    branches=`git ls-tree -r -t git-svn \
              | egrep '/trunk$|/(branches|tags)/[^/]+$' \
              | sed -e 's/^.*\t//' \
              | while read b; do
                  git rev-list --reverse $b -- | head -n1 \
                  | xargs git cat-file commit | grep ^author \
                  | sed -e "s;^.*> \([0-9]\+\).*;\1 $b;"
              done | sort -n | awk '{$1="";print}'`
    rm -f $WORK_DIR/reparented-branches
    touch $WORK_DIR/reparented-branches
    rm -f .git/info/grafts
    for b in $branches; do
        if grep -q $b $WORK_DIR/reparented-branches; then
            #echo "*   Skipping branch $b"   
            continue
        fi
        echo "*   Considering branch $b ..."   
        orig=$(git rev-list --reverse $b -- | head -n1);
        orig_tree=$(git cat-file commit $orig | grep ^tree);

        # Only try to reparent to commits older than the orig commit.
        git rev-list --date-order --all | sed -e "1,/$orig/ d" |
        while read h; do
            # for each candidate, see if it shares a common root tree with
            # orig_tree.
            if git cat-file commit $h | grep -q "$orig_tree"; then
                echo "*     grafting in $(git branch --contains $h |
                                          tr '\n' ',') at $h"
                echo "$orig $h" >> .git/info/grafts
                break
            fi
        done
        if grep -q $orig .git/info/grafts 2>/dev/null; then
            git filter-branch --original /dev/null -- $b
        else
            echo $b >> $WORK_DIR/reparented-branches
        fi
    done
}

do_convert_tags() {
    echo "*"
    echo "* Converting tag svn branches to git tags"
    echo "*"
    branches=`find $GIT_DIR/refs/heads -type f |
              grep -e '/tags/' |
              sed -e "s;^$GIT_DIR/refs/heads/;;g"`
    for b in $branches; do
        tag=$(echo $b | sed -e 's;\(.*\)/tags/\(.*\);\1/\2;')
        echo "*   creating tag $tag"
        git tag -f $tag $b
        git branch -D $b
    done
}

# Handle command line options
for opt; do
    optval="${opt#*=}"
    case $opt in
        --init)  action=init ;;
        --time)  time=$(which time 2>/dev/null) || time="time" ;;
        --url=*) export URL_BASE=$optval ;;
        --url)
        echo "option $opt requires argument"
        exit 1
        ;;
        *)
        if [ "$action" == "init" ]; then
            svn_fetch_flags="$svn_fetch_flags $opt"
        else 
            echo "unrecognized option $opt"
            exit 1
        fi
        ;;
    esac
done

case `basename $0` in
    apply-externals) do_apply ;;
    index-filter)    index_filter ;;
    rearrange-heads) do_rearrange ;;
    reparent-heads)  do_reparent ;;
    convert-tags)    do_convert_tags ;;
    *)

    case "$action" in
        init)
        [ -z "$URL_BASE" ] && echo "URL_BASE not set" && exit 1
        [ ! -d $GIT_DIR ] && { git init || exit $?; }

        # Prepare our working directory.
        mkdir -p $WORK_DIR/rev-cache
        for f in apply-externals index-filter rearrange-heads \
                 reparent-heads convert-tags; do
            ln -sf $(cd $(dirname $0) && pwd)/$(basename $0) $WORK_DIR/$f
        done

        grep -q svn-remote $GIT_DIR/config || git svn init $URL_BASE || exit $?
        git svn fetch -q $svn_fetch_flags
        
        ;;
        $WORK_DIR/*) $time $action ;;
        "")
        # Ensure that we're working in a repo
        [ ! -d $GIT_DIR ] && echo "Couldn't find $GIT_DIR directory." && exit 1

        $time $WORK_DIR/apply-externals \
        && $time $WORK_DIR/rearrange-heads \
        && $time $WORK_DIR/reparent-heads \
        && $time $WORK_DIR/convert-tags 
        ;;
        *)
        echo "Unrecognized action $action"
        exit 1
    esac
esac
