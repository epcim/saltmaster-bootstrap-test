#!/bin/bash -e

# ENVIRONMENT
####

SUDO=${SUDO:-sudo}

SALT_SOURCE=${SALT_SOURCE:-pkg}
SALT_VERSION=${SALT_VERSION:-latest}

if [ "$FORMULA_SOURCE" == "git" ]; then
  SALT_ENV=${SALT_ENV:-dev}
elif [ "$FORMULA_SOURCE" == "pkg" ]; then
  SALT_ENV=${SALT_ENV:-prd}
fi

eval $(cat /etc/*release 2> /dev/null)
PLATFORM_FAMILY=$(echo ${ID_LIKE// */} | tr A-Z a-z)

case $PLATFORM_FAMILY in
  debian )
      PKGTOOL="$SUDO apt-get"
      test ${VERSION_ID//\.*/} -ge 16 && {
        SVCTOOL=service
      } || { SVCTOOL=service
      }
    ;;
  rhel )
      PKGTOOL="$SUDO yum"
      test ${VERSION_ID//\.*/} -ge 7 && {
        SVCTOOL=systemctl
      } || { SVCTOOL=service
      }
    ;;
esac

export PLATFORM_FAMILY
export PKGTOOL
export SVCTOOL

# FUNCTIONS
####
configure_pkg_repo()
{

    case $PLATFORM_FAMILY in
      debian)
          echo -e  "$APT_REPOSITORY " > /etc/apt/sources.list
          wget -O - $APT_REPOSITORY_GPG | apt-key add -
          $SUDO apt-get clean
          $SUDO apt-get update
        ;;
      rhel)
          $SUDO yum install -y https://repo.saltstack.com/yum/redhat/salt-repo-latest-1.el${VERSION_ID}.noarch.rpm
          $SUDO yum clean all
        ;;
    esac
}

# DEPRECATED
purge_system()
{

  # debian
  if [ -x "`which invoke-rc.d 2>/dev/null`" -a -x "/etc/init.d/salt-minion" ] ; then
    $SUDO apt-get purge -y salt-minion salt-common && $SUDO apt-get autoremove -y
  fi

  # rhel
  if [ -x "`which invoke-rc.d 2>/dev/null`" -a -x "/etc/init.d/salt-minion" ] ; then
    $SUDO yum remove -y salt-minion salt-common && $SUDO yum autoremove -y
  fi
}

configure_salt_master()
{

  echo "Configuring salt-master ..."

  [ ! -d /etc/salt/master.d ] && mkdir -p /etc/salt/master.d
  cat <<-'EOF' > /etc/salt/master.d/master.conf
    file_roots:
      base:
      - /usr/share/salt-formulas/env
    pillar_opts: False
    open_mode: True
    reclass: &reclass
      storage_type: yaml_fs
      inventory_base_uri: /srv/salt/reclass
    ext_pillar:
      - reclass: *reclass
    master_tops:
      reclass: *reclass
EOF

  echo "Configuring reclass ..."

  [ ! -d /etc/reclass ] && mkdir /etc/reclass
  cat <<-'EOF' > /etc/reclass/reclass-config.yml
    storage_type: yaml_fs
    pretty_print: True
    output: yaml
    inventory_base_uri: /srv/salt/reclass
EOF

  if [ ! -e /srv/salt/reclass/.git ]; then
    git clone ${RECLASS_ADDRESS} /srv/salt/reclass -b ${RECLASS_BRANCH:-master}
  else
    git fetch /srv/salt/reclass 
  fi

  [[ -f "/srv/salt/reclass/nodes/${MINION_ID}.yml" ]] || {
    cat <<-EOF > /srv/salt/reclass/nodes/${MINION_ID}.yml
    classes:
    - service.git.client
    - system.linux.system.single
    - system.openssh.client.workshop
    - system.salt.master.single
    - system.salt.master.formula.$FORMULA_SOURCE
    - system.reclass.storage.salt
    parameters:
      _param:
        reclass_data_repository: "$RECLASS_ADDRESS"
        reclass_data_revision: ${RECLASS_BRANCH:-master}
        salt_formula_branch: ${FORMULA_GIT_BRANCH:-master}
        reclass_config_master: $SALT_MASTER
        single_address: $SALT_MASTER
        salt_master_host: $SALT_MASTER
        salt_master_base_environment: $SALT_ENV
      linux:
        system:
          name: $MINION_ID
          domain: $DOMAIN
EOF

    if [ "$SALT_VERSION" == "latest" ]; then
      VERSION=""
    else
      VERSION="version: $SALT_VERSION"
    fi

    cat <<-EOF >> /srv/salt/reclass/nodes/${MINION_ID}.yml
    salt:
      master:
        accept_policy: open_mode
        source:
          engine: $SALT_SOURCE
          $VERSION
      minion:
        source:
          engine: $SALT_SOURCE
          $VERSION
EOF
  }
}

configure_salt_minion()
{
    [ ! -d /etc/salt/minion.d ] && mkdir -p /etc/salt/minion.d
    cat <<-EOF > /etc/salt/minion.d/minion.conf
    master: $SALT_MASTER
    id: $MINION_ID
EOF

}


install_salt_master_pkg()
{
    echo -e "\nPreparing base OS repository ...\n"

    configure_pkg_repo

    echo -e "\nInstalling salt master ...\n"

    case $PLATFORM_FAMILY in
      debian)
          $SUDO apt-get install -y reclass git
          if [ "$SALT_VERSION" == "latest" ]; then
            $SUDO apt-get install -y salt-common salt-master
          else
            $SUDO apt-get install -y --force-yes salt-common=$SALT_VERSION salt-master=$SALT_VERSION
          fi
        ;;
      rhel)
          # TODO review rhel
          #if [ "$SALT_VERSION" == "latest" ]; then
              #$SUDO yum install -y salt-master
          #else
              #$SUDO yum install -y salt-master-SALT_VERSION
          #fi
        ;;
    esac

    configure_salt_master

    echo -e "\nRestarting services ...\n"
    [ -f /etc/salt/pki/minion/minion_master.pub ] && rm -f /etc/salt/pki/minion/minion_master.pub
    $SVCTOOL salt-master restart
}

install_salt_master_pip()
{
    echo -e "\nPreparing base OS repository ...\n"

    case $PLATFORM_FAMILY in
      debian)
          $SUDO apt-get install -y python-pip python-dev zlib1g-dev reclass git
        ;;
      rhel)
          # TODO
        ;;
    esac

    echo -e "\nInstalling salt master ...\n"

    if [ "$SALT_VERSION" == "latest" ]; then
      pip install salt
    else
      pip install salt==$SALT_VERSION
    fi

    wget -O /etc/init.d/salt-master https://anonscm.debian.org/cgit/pkg-salt/salt.git/plain/debian/salt-master.init && chmod 755 /etc/init.d/salt-master
    ln -s /usr/local/bin/salt-master /usr/bin/salt-master

    configure_salt_master

    echo -e "\nRestarting services ...\n"
    [ -f /etc/salt/pki/minion/minion_master.pub ] && rm -f /etc/salt/pki/minion/minion_master.pub
    $SVCTOOL salt-master restart
}



install_salt_minion_pkg()
{

    configure_pkg_repo

    echo -e "\nInstalling salt minion ...\n"

    case $PLATFORM_FAMILY in
      debian)
        if [ "$SALT_VERSION" == "latest" ]; then
          $SUDO apt-get install -y salt-common salt-minion
        else
          $SUDO apt-get install -y --force-yes salt-common=$SALT_VERSION salt-minion=$SALT_VERSION
        fi
      ;;
      rhel)
        # TODO, review rhel versioN
        #if [ "$SALT_VERSION" == "LATEST" ]; then
            #$SUDO yum install -y salt-minion
        #else
            #$SUDO yum install -y salt-minion-$SALT_VERSION
        #fi
      ;;
    esac


    configure_salt_minion

    $SVCTOOL salt-minion restart
}

install_salt_minion_pip()
{
    echo -e "\nInstalling salt minion ...\n"

    wget -O /etc/init.d/salt-minion https://anonscm.debian.org/cgit/pkg-salt/salt.git/plain/debian/salt-minion.init && chmod 755 /etc/init.d/salt-minion
    ln -s /usr/local/bin/salt-minion /usr/bin/salt-minion

    configure_salt_minion
    $SVCTOOL salt-minion restart
}


install_salt_formula_pkg()
{
    configure_pkg_repo

    case $PLATFORM_FAMILY in
      debian)
          echo "Configuring necessary formulas ..."

          [ ! -d /srv/salt/reclass/classes/service ] && mkdir -p /srv/salt/reclass/classes/service

          declare -a formula_services=("linux" "reclass" "salt" "openssh" "ntp" "git")

          for formula_service in "${formula_services[@]}"; do
              echo -e "\nConfiguring salt formula ${formula_service} ...\n"
              [ ! -d "${FORMULA_PATH}/env/${formula_service}" ] && \
                  $SUDO apt-get install -y salt-formula-${formula_service}
              [ ! -L "/srv/salt/reclass/classes/service/${formula_service}" ] && \
                  ln -s ${FORMULA_PATH}/reclass/service/${formula_service} /srv/salt/reclass/classes/service/${formula_service}
          done
        ;;
      rhel)
        # TODO
      ;;
    esac

    [ ! -d /srv/salt/env ] && mkdir -p /srv/salt/env
    [ ! -L /srv/salt/env/prd ] && ln -s ${FORMULA_PATH}/env /srv/salt/env/prd
}

install_salt_formula_git()
{
    echo "Configuring necessary formulas ..."

    [ ! -d /srv/salt/reclass/classes/service ] && mkdir -p /srv/salt/reclass/classes/service

    declare -a formula_services=("linux" "reclass" "salt" "openssh" "ntp" "git" "nginx" "collectd" "sensu" "heka" "sphinx")
    for formula_service in "${formula_services[@]}"; do
        echo -e "\nConfiguring salt formula ${formula_service} ...\n"
        [ ! -d "${FORMULA_PATH}/env/_formulas/${formula_service}" ] && \
            git clone ${FORMULA_GIT_BASE_URL}/salt-formula-${formula_service}.git ${FORMULA_PATH}/env/_formulas/${formula_service} -b ${FORMULA_BRANCH:-master}
        [ ! -L "/usr/share/salt-formulas/env/${formula_service}" ] && \
            ln -s ${FORMULA_PATH}/env/_formulas/${formula_service}/${formula_service} /usr/share/salt-formulas/env/${formula_service}
        [ ! -L "/srv/salt/reclass/classes/service/${formula_service}" ] && \
            ln -s ${FORMULA_PATH}/env/_formulas/${formula_service}/metadata/service /srv/salt/reclass/classes/service/${formula_service}
    done

    [ ! -d /srv/salt/env ] && mkdir -p /srv/salt/env
    [ ! -L /srv/salt/env/dev ] && ln -s /usr/share/salt-formulas/env /srv/salt/env/dev
}





# MAIN
####

# detect if file is being sourced
# bash/korn shell compatible
#[[ "$0" != "$_" ]] && main "$@"
# bash way
[[ "$0" != "$BASH_SOURCE" ]] || {

  # DEBUGING
  #set -x
  #test -e $(dirname $0)/env/salt.env && source $(dirname $0)/env/salt.env

  # CLI
  while [ x"$1" != x"" ]; do
    # PREREQ
    which wget &>/dev/null || $PKGTOOL -y install wget &>/dev/null

    case $1 in
        master )
          install_salt_master_$SALT_SOURCE
          install_salt_minion_$SALT_SOURCE
          install_salt_formula_$FORMULA_SOURCE
          ;;
        minion )
          install_salt_minion_$SALT_SOURCE
          ;;
    esac
    shift
  done
  echo DONE

}
