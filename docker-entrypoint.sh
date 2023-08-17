#!/usr/bin/env bash
set -Eeo pipefail
# TODO swap to -Eeuo pipefail above (after handling all potentially-unset variables)

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		printf >&2 'error: both %s and %s are set (but are exclusive)\n' "$var" "$fileVar"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# check to see if this file is being run or sourced from another script
_is_sourced() {
	# https://unix.stackexchange.com/a/215279
	[ "${#FUNCNAME[@]}" -ge 2 ] \
		&& [ "${FUNCNAME[0]}" = '_is_sourced' ] \
		&& [ "${FUNCNAME[1]}" = 'source' ]
}

# used to create initial postgres directories and if run as root, ensure ownership to the "postgres" user
docker_create_db_directories() {
	local user; user="$(id -u)"

	mkdir -p "$PGDATA"
	# ignore failure since there are cases where we can't chmod (and PostgreSQL might fail later anyhow - it's picky about permissions of this directory)
	chmod 00700 "$PGDATA" || :

	# ignore failure since it will be fine when using the image provided directory; see also https://github.com/docker-library/postgres/pull/289
	mkdir -p /var/run/postgresql || :
	chmod 03775 /var/run/postgresql || :

	# Create the transaction log directory before initdb is run so the directory is owned by the correct user
	if [ -n "${POSTGRES_INITDB_WALDIR:-}" ]; then
		mkdir -p "$POSTGRES_INITDB_WALDIR"
		if [ "$user" = '0' ]; then
			find "$POSTGRES_INITDB_WALDIR" \! -user postgres -exec chown postgres '{}' +
		fi
		chmod 700 "$POSTGRES_INITDB_WALDIR"
	fi

	# allow the container to be started with `--user`
	if [ "$user" = '0' ]; then
		find "$PGDATA" \! -user postgres -exec chown postgres '{}' +
		find /var/run/postgresql \! -user postgres -exec chown postgres '{}' +
	fi
}

# initialize empty PGDATA directory with new database via 'initdb'
# arguments to `initdb` can be passed via POSTGRES_INITDB_ARGS or as arguments to this function
# `initdb` automatically creates the "postgres", "template0", and "template1" dbnames
# this is also where the database user is created, specified by `POSTGRES_USER` env
docker_init_database_dir() {
	# "initdb" is particular about the current user existing in "/etc/passwd", so we use "nss_wrapper" to fake that if necessary
	# see https://github.com/docker-library/postgres/pull/253, https://github.com/docker-library/postgres/issues/359, https://cwrap.org/nss_wrapper.html
	local uid; uid="$(id -u)"
	if ! getent passwd "$uid" &> /dev/null; then
		# see if we can find a suitable "libnss_wrapper.so" (https://salsa.debian.org/sssd-team/nss-wrapper/-/commit/b9925a653a54e24d09d9b498a2d913729f7abb15)
		local wrapper
		for wrapper in {/usr,}/lib{/*,}/libnss_wrapper.so; do
			if [ -s "$wrapper" ]; then
				NSS_WRAPPER_PASSWD="$(mktemp)"
				NSS_WRAPPER_GROUP="$(mktemp)"
				export LD_PRELOAD="$wrapper" NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
				local gid; gid="$(id -g)"
				printf 'postgres:x:%s:%s:PostgreSQL:%s:/bin/false\n' "$uid" "$gid" "$PGDATA" > "$NSS_WRAPPER_PASSWD"
				printf 'postgres:x:%s:\n' "$gid" > "$NSS_WRAPPER_GROUP"
				break
			fi
		done
	fi

	if [ -n "${POSTGRES_INITDB_WALDIR:-}" ]; then
		set -- --waldir "$POSTGRES_INITDB_WALDIR" "$@"
	fi

	# --pwfile refuses to handle a properly-empty file (hence the "\n"): https://github.com/docker-library/postgres/issues/1025
	eval 'initdb --username="$POSTGRES_USER" --pwfile=<(printf "%s\n" "$POSTGRES_PASSWORD") '"$POSTGRES_INITDB_ARGS"' "$@"'

	# unset/cleanup "nss_wrapper" bits
	if [[ "${LD_PRELOAD:-}" == */libnss_wrapper.so ]]; then
		rm -f "$NSS_WRAPPER_PASSWD" "$NSS_WRAPPER_GROUP"
		unset LD_PRELOAD NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
	fi
}

# print large warning if POSTGRES_PASSWORD is long
# error if both POSTGRES_PASSWORD is empty and POSTGRES_HOST_AUTH_METHOD is not 'trust'
# print large warning if POSTGRES_HOST_AUTH_METHOD is set to 'trust'
# assumes database is not set up, ie: [ -z "$DATABASE_ALREADY_EXISTS" ]
docker_verify_minimum_env() {
	# check password first so we can output the warning before postgres
	# messes it up
	if [ "${#POSTGRES_PASSWORD}" -ge 100 ]; then
		cat >&2 <<-'EOWARN'

			WARNING: The supplied POSTGRES_PASSWORD is 100+ characters.

			  This will not work if used via PGPASSWORD with "psql".

			  https://www.postgresql.org/message-id/flat/E1Rqxp2-0004Qt-PL%40wrigleys.postgresql.org (BUG #6412)
			  https://github.com/docker-library/postgres/issues/507

		EOWARN
	fi
	if [ -z "$POSTGRES_PASSWORD" ] && [ 'trust' != "$POSTGRES_HOST_AUTH_METHOD" ]; then
		# The - option suppresses leading tabs but *not* spaces. :)
		cat >&2 <<-'EOE'
			Error: Database is uninitialized and superuser password is not specified.
			       You must specify POSTGRES_PASSWORD to a non-empty value for the
			       superuser. For example, "-e POSTGRES_PASSWORD=password" on "docker run".

			       You may also use "POSTGRES_HOST_AUTH_METHOD=trust" to allow all
			       connections without a password. This is *not* recommended.

			       See PostgreSQL documentation about "trust":
			       https://www.postgresql.org/docs/current/auth-trust.html
		EOE
		exit 1
	fi
	if [ 'trust' = "$POSTGRES_HOST_AUTH_METHOD" ]; then
		cat >&2 <<-'EOWARN'
			********************************************************************************
			WARNING: POSTGRES_HOST_AUTH_METHOD has been set to "trust". This will allow
			         anyone with access to the Postgres port to access your database without
			         a password, even if POSTGRES_PASSWORD is set. See PostgreSQL
			         documentation about "trust":
			         https://www.postgresql.org/docs/current/auth-trust.html
			         In Docker's default configuration, this is effectively any other
			         container on the same system.

			         It is not recommended to use POSTGRES_HOST_AUTH_METHOD=trust. Replace
			         it with "-e POSTGRES_PASSWORD=password" instead to set a password in
			         "docker run".
			********************************************************************************
		EOWARN
	fi
}

# usage: docker_process_init_files [file [file [...]]]
#    ie: docker_process_init_files /always-initdb.d/*
# process initializer files, based on file extensions and permissions
docker_process_init_files() {
	# psql here for backwards compatibility "${psql[@]}"
	psql=( docker_process_sql )

	printf '\n'
	local f
	for f; do
		case "$f" in
			*.sh)
				# https://github.com/docker-library/postgres/issues/450#issuecomment-393167936
				# https://github.com/docker-library/postgres/pull/452
				if [ -x "$f" ]; then
					printf '%s: running %s\n' "$0" "$f"
					"$f"
				else
					printf '%s: sourcing %s\n' "$0" "$f"
					. "$f"
				fi
				;;
			*.sql)     printf '%s: running %s\n' "$0" "$f"; docker_process_sql -f "$f"; printf '\n' ;;
			*.sql.gz)  printf '%s: running %s\n' "$0" "$f"; gunzip -c "$f" | docker_process_sql; printf '\n' ;;
			*.sql.xz)  printf '%s: running %s\n' "$0" "$f"; xzcat "$f" | docker_process_sql; printf '\n' ;;
			*.sql.zst) printf '%s: running %s\n' "$0" "$f"; zstd -dc "$f" | docker_process_sql; printf '\n' ;;
			*)         printf '%s: ignoring %s\n' "$0" "$f" ;;
		esac
		printf '\n'
	done
}

# Execute sql script, passed via stdin (or -f flag of pqsl)
# usage: docker_process_sql [psql-cli-args]
#    ie: docker_process_sql --dbname=mydb <<<'INSERT ...'
#    ie: docker_process_sql -f my-file.sql
#    ie: docker_process_sql <my-file.sql
docker_process_sql() {
	local query_runner=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password --no-psqlrc )
	if [ -n "$POSTGRES_DB" ]; then
		query_runner+=( --dbname "$POSTGRES_DB" )
	fi

	PGHOST= PGHOSTADDR= "${query_runner[@]}" "$@"
}

# create initial database
# uses environment variables for input: POSTGRES_DB
docker_setup_db() {
	local dbAlreadyExists
	dbAlreadyExists="$(
		POSTGRES_DB= docker_process_sql --dbname postgres --set db="$POSTGRES_DB" --tuples-only <<-'EOSQL'
			SELECT 1 FROM pg_database WHERE datname = :'db' ;
		EOSQL
	)"
	if [ -z "$dbAlreadyExists" ]; then
		POSTGRES_DB= docker_process_sql --dbname postgres --set db="$POSTGRES_DB" <<-'EOSQL'
			CREATE DATABASE :"db" ;
		EOSQL
		printf '\n'
	fi
}

# Loads various settings that are used elsewhere in the script
# This should be called before any other functions
docker_setup_env() {
	file_env 'POSTGRES_PASSWORD'

	file_env 'POSTGRES_USER' 'postgres'
	file_env 'POSTGRES_DB' "$POSTGRES_USER"
	file_env 'POSTGRES_INITDB_ARGS'
	: "${POSTGRES_HOST_AUTH_METHOD:=}"

	declare -g DATABASE_ALREADY_EXISTS
	# look specifically for PG_VERSION, as it is expected in the DB dir
	if [ -s "$PGDATA/PG_VERSION" ]; then
		DATABASE_ALREADY_EXISTS='true'
	fi
}

# append POSTGRES_HOST_AUTH_METHOD to pg_hba.conf for "host" connections
# all arguments will be passed along as arguments to `postgres` for getting the value of 'password_encryption'
pg_setup_hba_conf() {
	# default authentication method is md5 on versions before 14
	# https://www.postgresql.org/about/news/postgresql-14-released-2318/
	if [ "$1" = 'postgres' ]; then
		shift
	fi
	local auth
	# check the default/configured encryption and use that as the auth method
	auth="$(postgres -C password_encryption "$@")"
	: "${POSTGRES_HOST_AUTH_METHOD:=$auth}"
	{
		printf '\n'
		if [ 'trust' = "$POSTGRES_HOST_AUTH_METHOD" ]; then
			printf '# warning trust is enabled for all connections\n'
			printf '# see https://www.postgresql.org/docs/12/auth-trust.html\n'
		fi
		printf 'host all all all %s\n' "$POSTGRES_HOST_AUTH_METHOD"
	} >> "$PGDATA/pg_hba.conf"
}

# start socket-only postgresql server for setting up or running scripts
# all arguments will be passed along as arguments to `postgres` (via pg_ctl)
docker_temp_server_start() {
	if [ "$1" = 'postgres' ]; then
		shift
	fi

	# internal start of server in order to allow setup using psql client
	# does not listen on external TCP/IP and waits until start finishes
	set -- "$@" -c listen_addresses='' -p "${PGPORT:-5432}"

	PGUSER="${PGUSER:-$POSTGRES_USER}" \
	pg_ctl -D "$PGDATA" \
		-o "$(printf '%q ' "$@")" \
		-w start
}

# stop postgresql server after done setting up user and running scripts
docker_temp_server_stop() {
	PGUSER="${PGUSER:-postgres}" \
	pg_ctl -D "$PGDATA" -m fast -w stop
}

# Initialise PG data directory in a temp location with a specific locale
initdb_locale() {
	echo "Initialising PostgreSQL 15 data directory"
	/usr/local/bin/initdb --username="${POSTGRES_USER}" --locale=${1} /var/lib/postgresql/data/new/
}

# check arguments for an option that would cause postgres to stop
# return true if there is one
_pg_want_help() {
	local arg
	for arg; do
		case "$arg" in
			# postgres --help | grep 'then exit'
			# leaving out -C on purpose since it always fails and is unhelpful:
			# postgres: could not access the server configuration file "/var/lib/postgresql/data/postgresql.conf": No such file or directory
			-'?'|--help|--describe-config|-V|--version)
				return 0
				;;
		esac
	done
	return 1
}

_main() {
	# if first arg looks like a flag, assume we want to run postgres server
	if [ "${1:0:1}" = '-' ]; then
		set -- postgres "$@"
	fi

	if [ "$1" = 'postgres' ] && ! _pg_want_help "$@"; then
		docker_setup_env
		# setup data directories and permissions (when run as root)
		docker_create_db_directories
		if [ "$(id -u)" = '0' ]; then
			# then restart script as postgres user
			exec su-exec postgres "$BASH_SOURCE" "$@"
		fi

		# only run initialization on an empty data directory
		if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
			docker_verify_minimum_env

			# check dir permissions to reduce likelihood of half-initialized database
			ls /docker-entrypoint-initdb.d/ > /dev/null

			docker_init_database_dir
			pg_setup_hba_conf "$@"

			# PGPASSWORD is required for psql when authentication is required for 'local' connections via pg_hba.conf and is otherwise harmless
			# e.g. when '--auth=md5' or '--auth-local=md5' is used in POSTGRES_INITDB_ARGS
			export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
			docker_temp_server_start "$@"

			docker_setup_db
			docker_process_init_files /docker-entrypoint-initdb.d/*

			docker_temp_server_stop
			unset PGPASSWORD

			cat <<-'EOM'

				PostgreSQL init process complete; ready for start up.

			EOM
		else
			cat <<-'EOM'

				PostgreSQL Database directory appears to contain a database; Skipping initialization

			EOM
		fi
	fi

	# For development of pgautoupgrade.  This spot leaves the container running, prior to the pgautoupgrade scripting
	# executing
	if [ "x${PGAUTO_DEVEL}" = "xbefore" ]; then
		echo "---------------------------------------------------------------------------"
		echo "In pgautoupgrade development mode, paused prior to pgautoupgrade scripting."
		echo "---------------------------------------------------------------------------"
		while :; do
			sleep 5
		done
	else
		### The main pgautoupgrade scripting starts here ###

		# Get the version of the PostgreSQL data files
		local PGVER=${PGTARGET}
		if [ -s "$PGDATA/PG_VERSION" ]; then
			PGVER=$(cat "$PGDATA/PG_VERSION")
		fi

		# If the version of PostgreSQL isn't 15, then upgrade the data files
		if [ "${PGVER}" != "${PGTARGET}" ]; then
			echo "*******************************************************************************************"
			echo "Performing PG upgrade on version ${PGVER} database files.  Upgrading to version ${PGTARGET}"
			echo "*******************************************************************************************"

			# Check for presence of old/new directories, indicating a failed previous autoupgrade
			echo "----------------------------------------------------------------------"
			echo "Checking for left over artifacts from a failed previous autoupgrade..."
			echo "----------------------------------------------------------------------"
			local OLD="${PGDATA}/old"
			local NEW="${PGDATA}/new"
			if [ -d "${OLD}" ]; then
				echo "*****************************************"
				echo "Left over OLD directory found.  Aborting."
				echo "*****************************************"
				exit 10
			fi
			if [ -d "${NEW}" ]; then
				echo "*****************************************"
				echo "Left over NEW directory found.  Aborting."
				echo "*****************************************"
				exit 11
			fi
			echo "-------------------------------------------------------------------------------"
			echo "No artifacts found from a failed previous autoupgrade.  Continuing the process."
			echo "-------------------------------------------------------------------------------"

			# Don't automatically abort on non-0 exit status, as that messes with these upcoming mv commands
			set +e

			# Move the PostgreSQL data files into a subdirectory of the mount point
			echo "---------------------------------------"
			echo "Creating OLD temporary directory ${OLD}"
			echo "---------------------------------------"
			mkdir "${OLD}"
			if [ ! -d "${OLD}" ]; then
				echo "*********************************************************************"
				echo "Creation of temporary directory '${OLD}' failed.  Aborting completely"
				echo "*********************************************************************"
				exit 7
			fi

			echo "-------------------------------------------------------"
			echo "Moving existing data files into OLD temporary directory"
			echo "-------------------------------------------------------"
			mv -v "${PGDATA}"/* "${OLD}"

			echo "---------------------------------------"
			echo "Creating NEW temporary directory ${NEW}"
			echo "---------------------------------------"
			mkdir "${NEW}"
			if [ ! -d "${NEW}" ]; then
				echo "********************************************************************"
				echo "Creation of temporary directory '${NEW}' failed. Aborting completely"
				echo "********************************************************************"
				# With a failure at this point we should be able to move the old data back
				# to its original location
				mv -v "${OLD}"/* "${PGDATA}"
				exit 8
			fi
			chmod 0700 "${OLD}" "${NEW}"

			# Return the error handling back to automatically aborting on non-0 exit status
			set -e

			# Perform the data directory upgrade
			local RECOGNISED=0
			if [ "${PGVER}" = "9.5" ]; then
				RECOGNISED=1
				echo "------------------------------------------------------------------------"
				echo "PostgreSQL 9.5 database files found, upgrading to PostgreSQL ${PGTARGET}"
				echo "------------------------------------------------------------------------"

				# Initialise the new data directory using the same collation as the old one
				COLL=$(echo 'SHOW LC_COLLATE' | /usr/local-pg9.5/bin/postgres --single -D "${OLD}" | grep 'lc_collate = "' | cut -d '"' -f 2)
				echo "---------------------------------------------------------------------------------------"
				echo "Old database using collation: '${COLL}'.  Initialising new database with that collation"
				echo "---------------------------------------------------------------------------------------"
				initdb_locale "${COLL}"
				cd "${PGDATA}"
				echo "---------------------------------------"
				echo "Running pg_upgrade command, from $(pwd)"
				echo "---------------------------------------"
				/usr/local/bin/pg_upgrade --username="${POSTGRES_USER}" --link -d "${OLD}" -D "${NEW}" -b /usr/local-pg9.5/bin -B /usr/local/bin
				echo "---------------------------"
				echo "pg_upgrade command finished"
				echo "---------------------------"
			elif [ "${PGVER}" = "9.6" ]; then
				RECOGNISED=1
				echo "------------------------------------------------------------------------"
				echo "PostgreSQL 9.6 database files found, upgrading to PostgreSQL ${PGTARGET}"
				echo "------------------------------------------------------------------------"

				# Initialise the new data directory using the same collation as the old one
				COLL=$(echo 'SHOW LC_COLLATE' | /usr/local-pg9.6/bin/postgres --single -D "${OLD}" | grep 'lc_collate = "' | cut -d '"' -f 2)
				echo "---------------------------------------------------------------------------------------"
				echo "Old database using collation: '${COLL}'.  Initialising new database with that collation"
				echo "---------------------------------------------------------------------------------------"
				initdb_locale "${COLL}"
				cd "${PGDATA}"
				echo "---------------------------------------"
				echo "Running pg_upgrade command, from $(pwd)"
				echo "---------------------------------------"
				/usr/local/bin/pg_upgrade --username="${POSTGRES_USER}" --link -d "${OLD}" -D "${NEW}" -b /usr/local-pg9.6/bin -B /usr/local/bin
				echo "---------------------------"
				echo "pg_upgrade command finished"
				echo "---------------------------"
			elif [ "${PGVER}" = "10" ]; then
				RECOGNISED=1
				echo "-----------------------------------------------------------------------"
				echo "PostgreSQL 10 database files found, upgrading to PostgreSQL ${PGTARGET}"
				echo "-----------------------------------------------------------------------"

				# Initialise the new data directory using the same collation as the old one
				COLL=$(echo 'SHOW LC_COLLATE' | /usr/local-pg10/bin/postgres --single -D "${OLD}" | grep 'lc_collate = "' | cut -d '"' -f 2)
				echo "---------------------------------------------------------------------------------------"
				echo "Old database using collation: '${COLL}'.  Initialising new database with that collation"
				echo "---------------------------------------------------------------------------------------"
				initdb_locale "${COLL}"
				cd "${PGDATA}"
				echo "---------------------------------------"
				echo "Running pg_upgrade command, from $(pwd)"
				echo "---------------------------------------"
				/usr/local/bin/pg_upgrade --username="${POSTGRES_USER}" --link -d "${OLD}" -D "${NEW}" -b /usr/local-pg10/bin -B /usr/local/bin
				echo "---------------------------"
				echo "pg_upgrade command finished"
				echo "---------------------------"
			elif [ "${PGVER}" = "11" ]; then
				RECOGNISED=1
				echo "-----------------------------------------------------------------------"
				echo "PostgreSQL 11 database files found, upgrading to PostgreSQL ${PGTARGET}"
				echo "-----------------------------------------------------------------------"

				# Initialise the new data directory using the same collation as the old one
				COLL=$(echo 'SHOW LC_COLLATE' | /usr/local-pg11/bin/postgres --single -D "${OLD}" | grep 'lc_collate = "' | cut -d '"' -f 2)
				echo "---------------------------------------------------------------------------------------"
				echo "Old database using collation: '${COLL}'.  Initialising new database with that collation"
				echo "---------------------------------------------------------------------------------------"
				initdb_locale "${COLL}"
				cd "${PGDATA}"
				echo "---------------------------------------"
				echo "Running pg_upgrade command, from $(pwd)"
				echo "---------------------------------------"
				/usr/local/bin/pg_upgrade --username="${POSTGRES_USER}" --link -d "${OLD}" -D "${NEW}" -b /usr/local-pg11/bin -B /usr/local/bin
				echo "---------------------------"
				echo "pg_upgrade command finished"
				echo "---------------------------"
			elif [ "${PGVER}" = "12" ]; then
				RECOGNISED=1
				echo "-----------------------------------------------------------------------"
				echo "PostgreSQL 12 database files found, upgrading to PostgreSQL ${PGTARGET}"
				echo "-----------------------------------------------------------------------"

				# Initialise the new data directory using the same collation as the old one
				COLL=$(echo 'SHOW LC_COLLATE' | /usr/local-pg12/bin/postgres --single -D "${OLD}" | grep 'lc_collate = "' | cut -d '"' -f 2)
				echo "---------------------------------------------------------------------------------------"
				echo "Old database using collation: '${COLL}'.  Initialising new database with that collation"
				echo "---------------------------------------------------------------------------------------"
				initdb_locale "${COLL}"
				cd "${PGDATA}"
				echo "---------------------------------------"
				echo "Running pg_upgrade command, from $(pwd)"
				echo "---------------------------------------"
				/usr/local/bin/pg_upgrade --username="${POSTGRES_USER}" --link -d "${OLD}" -D "${NEW}" -b /usr/local-pg12/bin -B /usr/local/bin
				echo "---------------------------"
				echo "pg_upgrade command finished"
				echo "---------------------------"
			fi
			if [ "${PGTARGET}" -gt 13 ] && [ "${PGVER}" = "13" ]; then
				RECOGNISED=1
				echo "-----------------------------------------------------------------------"
				echo "PostgreSQL 13 database files found, upgrading to PostgreSQL ${PGTARGET}"
				echo "-----------------------------------------------------------------------"

				# Initialise the new data directory using the same collation as the old one
				COLL=$(echo 'SHOW LC_COLLATE' | /usr/local-pg13/bin/postgres --single -D "${OLD}" | grep 'lc_collate = "' | cut -d '"' -f 2)
				echo "---------------------------------------------------------------------------------------"
				echo "Old database using collation: '${COLL}'.  Initialising new database with that collation"
				echo "---------------------------------------------------------------------------------------"
				initdb_locale "${COLL}"
				cd "${PGDATA}"
				echo "---------------------------------------"
				echo "Running pg_upgrade command, from $(pwd)"
				echo "---------------------------------------"
				/usr/local/bin/pg_upgrade --username="${POSTGRES_USER}" --link -d "${OLD}" -D "${NEW}" -b /usr/local-pg13/bin -B /usr/local/bin
				echo "---------------------------"
				echo "pg_upgrade command finished"
				echo "---------------------------"
			fi
			if [ "${PGTARGET}" -gt 14 ] && [ "${PGVER}" = "14" ]; then
				RECOGNISED=1
				echo "-----------------------------------------------------------------------"
				echo "PostgreSQL 14 database files found, upgrading to PostgreSQL ${PGTARGET}"
				echo "-----------------------------------------------------------------------"

				# Initialise the new data directory using the same collation as the old one
				COLL=$(echo 'SHOW LC_COLLATE' | /usr/local-pg14/bin/postgres --single -D "${OLD}" | grep 'lc_collate = "' | cut -d '"' -f 2)
				echo "---------------------------------------------------------------------------------------"
				echo "Old database using collation: '${COLL}'.  Initialising new database with that collation"
				echo "---------------------------------------------------------------------------------------"
				initdb_locale "${COLL}"
				cd "${PGDATA}"
				echo "---------------------------------------"
				echo "Running pg_upgrade command, from $(pwd)"
				echo "---------------------------------------"
				/usr/local/bin/pg_upgrade --username="${POSTGRES_USER}" --link -d "${OLD}" -D "${NEW}" -b /usr/local-pg14/bin -B /usr/local/bin
				echo "---------------------------"
				echo "pg_upgrade command finished"
				echo "---------------------------"
			fi
			if [ "${RECOGNISED}" -ne 1 ]; then
				echo "***********************************************************************"
				echo "Unknown version of PostgreSQL database files found, aborting completely"
				echo "***********************************************************************"
				exit 9
			fi

			# Move the new database files into place
			echo "-------------------------------------------------------------"
			echo "Moving the new updated database files to the active directory"
			echo "-------------------------------------------------------------"
			mv -v "${NEW}"/* "${PGDATA}"

			# Re-use the pg_hba.conf and pg_ident.conf from the old data directory
			echo "--------------------------------------------------------------"
			echo "Copying the old pg_hba and pg_ident configuration files across"
			echo "--------------------------------------------------------------"
			cp -f "${OLD}/pg_hba.conf" "${OLD}/pg_ident.conf" "${PGDATA}"

			# Remove the left over database files
			echo "---------------------------------"
			echo "Removing left over database files"
			echo "---------------------------------"
			rm -rf "${OLD}" "${NEW}" ~/delete_old_cluster.sh

			echo "************************************************************"
			echo "Automatic upgrade process finished with no errors (reported)"
			echo "************************************************************"
		fi

		### The main pgautoupgrade scripting ends here ###
	fi

	# For development of pgautoupgrade.  This spot leaves the container running, after the pgautoupgrade scripting has
	# executed, but without subsequently running the PostgreSQL server
	if [ "x${PGAUTO_DEVEL}" = "xserver" ]; then
		echo "In pgautoupgrade development mode, so database server not started."
		while :; do
			sleep 5
		done
	else
		exec "$@"
	fi
}

if ! _is_sourced; then
	_main "$@"
fi
