#!/bin/bash

#=================================================
# COMMON VARIABLES
#=================================================

export appname="libreerp"
export FORKNAME="odoo"

swap_needed=1024

# dependencies used by the app
pkg_dependencies="curl postgresql xfonts-75dpi xfonts-base wkhtmltopdf node-less python3-dev gcc libldap2-dev libssl-dev libsasl2-dev python3-pip python3-dev python3-venv python3-wheel libxslt-dev libzip-dev python3-setuptools libjpeg-dev zlib1g-dev libfreetype6-dev libffi-dev libpq-dev"

#=================================================
# PERSONAL HELPERS
#=================================================

function debranding() {
	# Remove Odoo references to avoid trademark issue
	if [ -d $final_path/$appname/$FORKNAME ]; then
		python_app=$final_path/$appname/$FORKNAME
	else
		python_app=$final_path/$appname/openerp
	fi
	find $final_path/$appname -type f \( -iname '*.xml' -o -iname '*.po' \) -exec sed -i 's/Powered by <a[^>]*>Odoo<\/a>//g' {} \;
	find $final_path/$appname -type f \( -iname '*.xml' -o -iname '*.po' \) -exec sed -i 's/<a[^>]*>Powered by <[^>]*>Odoo<\/[^>]*><\/a>//g' {} \;
	find $final_path/$appname -type f \( -iname '*.xml' -o -iname '*.po' \) -exec sed -i 's/Powered by <[^>]*>Odoo<\/[^>]*>//g' {} \;
	find $final_path/$appname -type f \( -iname '*.xml' -o -iname '*.po' \) -exec sed -i 's/Powered by <[^>]*><img[^>]*Odoo[^>]*><\/a>//g' {} \;
	if test -f "$final_path/$appname/addons/web/static/src/xml/base.xml"; then
		sed -i 's/<a[^>]*>My Odoo.com account<\/a>//g' $final_path/$appname/addons/web/static/src/xml/base.xml
		sed -i 's/<a[^>]*>Documentation<\/a>//g' $final_path/$appname/addons/web/static/src/xml/base.xml
		sed -i 's/<a[^>]*>Support<\/a>//g' $final_path/$appname/addons/web/static/src/xml/base.xml
	fi
	cp ../conf/logo_type.png  $python_app/addons/base/static/img/logo_white.png
}

function setup_files() {
   
	if [[ $oca -eq 0 ]]; then
		ynh_setup_source $final_path/$appname $app_version
	else
		ynh_setup_source $final_path/$appname "oca-$app_version"
	fi
	debranding
	mkdir -p $final_path/custom-addons
	chmod 750 "$final_path"
	chmod -R o-rwx "$final_path"
	chown -R $app:$app "$final_path"
	touch /var/log/$app.log
	chown $app:$app /var/log/$app.log
	
	if [ ! -f $conf_file ]; then
		ynh_configure server.conf $conf_file
		chmod 400 "$conf_file"
		chown $app:$app "$conf_file"

		# Autoinstall the LDAP auth module
		if ls $final_path/$appname/$FORKNAME-bin > /dev/null ; then
			ynh_replace_string "^{$" "{'auto_install': True," $final_path/$appname/addons/auth_ldap/__manifest__.py
		else
			ynh_replace_string "'auto_install': False" "'auto_install': True" $final_path/$appname/addons/auth_ldap/__openerp__.py
		fi
	fi 

}

function setup_database() {
	export preinstall=1
	ynh_configure server.conf $conf_file
	chown $app:$app $conf_file
	# Load translation
	#param=" --without-demo True --addons-path $final_path/$appname/addons --db_user $app --db_password $db_pwd --db_host 127.0.0.1 --db_port 5432 --db-filter '^$app\$' -d $app "
	param=" -c $conf_file -d $app "
	ynh_exec_as $app $bin_file -c $conf_file --stop-after-init -i base -d $app
	ynh_exec_as $app $bin_file -c $conf_file --stop-after-init -i auth_ldap -d $app
	ynh_exec_as $app $bin_file -c $conf_file --stop-after-init --load-language $lang -d $app
	# Configure language, timezone and ldap
	ynh_exec_as $app $bin_file shell -c $conf_file -d $app <<< \
"
self.env['res.users'].search([['login', '=', 'admin']])[0].write({'password': '$admin_password'})
self.env.cr.commit()
"
	ynh_exec_as $app $bin_file shell -c $conf_file -d $app <<< \
"
self.write({'tz':'$tz','lang':'$lang'})
self.env.cr.commit()
"
	ynh_exec_as $app $bin_file shell -c $conf_file -d $app <<< \
"
template=env['res.users'].create({
  'login':'template',
  'password':'',
  'name':'template',
  'email':'template',
  'sel_groups_9_10':9,
  'tz':'$tz',
  'lang':'$lang'
})
self.env.cr.commit()
self.company_id.ldaps.create({
  'ldap_server':'localhost',
  'ldap_server_port':389,
  'ldap_base':'ou=users, dc=yunohost,dc=org',
  'ldap_filter':'uid=%s',
  'user':template.id,
  'company':self.company_id.id
})
self.env.cr.commit()
"
	export preinstall=0
	ynh_configure server.conf $conf_file
	chown $app:$app $conf_file
}

ynh_configure () {
	local TEMPLATE=$1
	local DEST=$2
	content=""
	content2=""
	content3=""
	if [[ $preinstall == '1' ]]
	then
		content="dbfilter = $db_name"
	else
		content="db_name = $db_name"
		if [[ $app_version > 9 ]]
		then
			content2="dbfilter = False"
		fi
		content3="list_db = False"
	fi

	mkdir -p "$(dirname $DEST)"
	if [ -f '../manifest.json' ] ; then
		ynh_add_config "${YNH_CWD}/../conf/$TEMPLATE" "$DEST"
	else
		ynh_add_config "${YNH_CWD}/../settings/conf/$TEMPLATE" "$DEST"
	fi
}

#=================================================
# EXPERIMENTAL HELPERS
#=================================================

# Add swap
#
# usage: ynh_add_swap --size=SWAP in Mb
# | arg: -s, --size= - Amount of SWAP to add in Mb.
ynh_add_swap () {
	# Declare an array to define the options of this helper.
	declare -Ar args_array=( [s]=size= )
	local size
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"

	local swap_max_size=$(( $size * 1024 ))

	local free_space=$(df --output=avail / | sed 1d)
	# Because we don't want to fill the disk with a swap file, divide by 2 the available space.
	local usable_space=$(( $free_space / 2 ))

	SD_CARD_CAN_SWAP=${SD_CARD_CAN_SWAP:-0}

	# Swap on SD card only if it's is specified
	if ynh_is_main_device_a_sd_card && [ "$SD_CARD_CAN_SWAP" == "0" ]
	then
		ynh_print_warn --message="The main mountpoint of your system '/' is on an SD card, swap will not be added to prevent some damage of this one, but that can cause troubles for the app $app. If you still want activate the swap, you can relaunch the command preceded by 'SD_CARD_CAN_SWAP=1'"
		return
	fi

	# Compare the available space with the size of the swap.
	# And set a acceptable size from the request
	if [ $usable_space -ge $swap_max_size ]
	then
		local swap_size=$swap_max_size
	elif [ $usable_space -ge $(( $swap_max_size / 2 )) ]
	then
		local swap_size=$(( $swap_max_size / 2 ))
	elif [ $usable_space -ge $(( $swap_max_size / 3 )) ]
	then
		local swap_size=$(( $swap_max_size / 3 ))
	elif [ $usable_space -ge $(( $swap_max_size / 4 )) ]
	then
		local swap_size=$(( $swap_max_size / 4 ))
	else
		echo "Not enough space left for a swap file" >&2
		local swap_size=0
	fi

	# If there's enough space for a swap, and no existing swap here
	if [ $swap_size -ne 0 ] && [ ! -e /swap_$app ]
	then
		# Check if / is mounted on btrfs
		if [ "$(awk '$2 == "/" {print $3}' /proc/mounts)" = "btrfs" ]
		then
			if [ "$(uname -r | awk -F. '{print $1}')" -lt 5 ]
			then
				ynh_print_warn --message="The main mountpoint of your system '/' is on an BTRFS filesystem, but current kernel does not support swap files on BTRFS. Swap file will not be added to prevent file system corruption. If you still want to activate the swap, please update your kernel to at least version 5."
				return
			fi
			truncate -s 0 /swap_$app
			chattr +C /swap_$app
		fi
		# Preallocate space for the swap file, fallocate may sometime not be used, use dd instead in this case
		if ! fallocate -l ${swap_size}K /swap_$app
		then
			dd if=/dev/zero of=/swap_$app bs=1024 count=${swap_size}
		fi
		chmod 0600 /swap_$app
		# Create the swap
		mkswap /swap_$app
		# And activate it
		swapon /swap_$app
		# Then add an entry in fstab to load this swap at each boot.
		echo -e "/swap_$app swap swap defaults 0 0 #Swap added by $app" >> /etc/fstab
	fi
}

ynh_del_swap () {
	# If there a swap at this place
	if [ -e /swap_$app ]
	then
		# Clean the fstab
		sed -i "/#Swap added by $app/d" /etc/fstab
		# Desactive the swap file
		swapoff /swap_$app
		# And remove it
		rm /swap_$app
	fi
}

# Check if the device of the main mountpoint "/" is an SD card
#
# [internal]
#
# return 0 if it's an SD card, else 1
ynh_is_main_device_a_sd_card () {
	local main_device=$(lsblk --output PKNAME --noheadings $(findmnt / --nofsroot --uniq --output source --noheadings --first-only))

	if echo $main_device | grep --quiet "mmc" && [ $(tail -n1 /sys/block/$main_device/queue/rotational) == "0" ]
	then
		return 0
	else
		return 1
	fi
}

#=================================================
# FUTURE OFFICIAL HELPERS
#=================================================
