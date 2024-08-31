#!/bin/bash

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

appname="libreerp"
FORKNAME="odoo"

swap_needed=1024

conf_file="/etc/$app/main.conf"

if [ "$app_version" = "9" ] || [ "$app_version" = "8" ]; then
    bin_file="$install_dir/venv/bin/python3 $install_dir/$appname/$FORKNAME.py"
else
    bin_file="$install_dir/venv/bin/python3 $install_dir/$appname/$FORKNAME-bin"
fi

function debranding() {
    # Remove Odoo references to avoid trademark issue
    if [ -d "$install_dir/$appname/$FORKNAME" ]; then
        python_app="$install_dir/$appname/$FORKNAME"
    else
        python_app="$install_dir/$appname/openerp"
    fi
    find "$install_dir/$appname" -type f \( -iname '*.xml' -o -iname '*.po' \) -exec sed -i 's/Powered by <a[^>]*>Odoo<\/a>//g' {} \;
    find "$install_dir/$appname" -type f \( -iname '*.xml' -o -iname '*.po' \) -exec sed -i 's/<a[^>]*>Powered by <[^>]*>Odoo<\/[^>]*><\/a>//g' {} \;
    find "$install_dir/$appname" -type f \( -iname '*.xml' -o -iname '*.po' \) -exec sed -i 's/Powered by <[^>]*>Odoo<\/[^>]*>//g' {} \;
    find "$install_dir/$appname" -type f \( -iname '*.xml' -o -iname '*.po' \) -exec sed -i 's/Powered by <[^>]*><img[^>]*Odoo[^>]*><\/a>//g' {} \;
    if test -f "$install_dir/$appname/addons/web/static/src/xml/base.xml"; then
        sed -i 's/<a[^>]*>My Odoo.com account<\/a>//g' "$install_dir/$appname/addons/web/static/src/xml/base.xml"
        sed -i 's/<a[^>]*>Documentation<\/a>//g' "$install_dir/$appname/addons/web/static/src/xml/base.xml"
        sed -i 's/<a[^>]*>Support<\/a>//g' "$install_dir/$appname/addons/web/static/src/xml/base.xml"
    fi
    cp ../conf/logo_type.png  "$python_app/addons/base/static/img/logo_white.png"
}

function setup_files() {
	source_id="main_${app_version}_oca"
    ynh_setup_source --source_id="$source_id" --dest_dir="$install_dir/$appname"

    debranding
    mkdir -p "$install_dir/custom-addons"

    #REMOVEME? Assuming the install dir is setup using ynh_setup_source, the proper chmod/chowns are now already applied and it shouldn't be necessary to tweak perms | chmod 750 "$install_dir"
    #REMOVEME? Assuming the install dir is setup using ynh_setup_source, the proper chmod/chowns are now already applied and it shouldn't be necessary to tweak perms | chmod -R o-rwx "$install_dir"
    #REMOVEME? Assuming the install dir is setup using ynh_setup_source, the proper chmod/chowns are now already applied and it shouldn't be necessary to tweak perms | chown -R "$app:$app" "$install_dir"
    touch "/var/log/$app.log"
    #REMOVEME? Assuming ynh_config_add_logrotate is called, the proper chmod/chowns are now already applied and it shouldn't be necessary to tweak perms | chown "$app:$app" "/var/log/$app.log"

    if [ ! -f "$conf_file" ]; then
		mkdir -p "$(dirname "$conf_file")"
        ynh_configure server.conf "$conf_file"
        chmod 400 "$conf_file"
        chown -R "$app:$app" "$(dirname "$conf_file")"

        # Autoinstall the LDAP auth module
        if [ -f "$install_dir/$appname/$FORKNAME-bin" ]; then
            ynh_replace --file="$install_dir/$appname/addons/auth_ldap/__manifest__.py" \
                --match="^{$" --replace="{'auto_install': True,"
        else
            ynh_replace --file="$install_dir/$appname/addons/auth_ldap/__openerp__.py" \
                --match="'auto_install': False" --replace="'auto_install': True"
        fi
    fi
}

function setup_database() {
    export preinstall=1
    ynh_configure server.conf "$conf_file"
    chown "$app:$app" "$conf_file"
    # Load translation
    #param=" --without-demo True --addons-path $install_dir/$appname/addons --db_user $app --db_password $db_pwd --db_host 127.0.0.1 --db_port 5432 --db-filter '^$app\$' -d $app "
    param=" -c $conf_file -d $app "
    ynh_exec_as_app $bin_file -c "$conf_file" --stop-after-init -i base -d "$app"
    ynh_exec_as_app $bin_file -c "$conf_file" --stop-after-init -i auth_ldap -d "$app"
    ynh_exec_as_app $bin_file -c "$conf_file" --stop-after-init --load-language $lang -d "$app"
    # Configure language, timezone and ldap
    ynh_exec_as_app $bin_file shell -c "$conf_file" -d "$app" <<< \
"
self.env['res.users'].search([['login', '=', 'admin']])[0].write({'password': '$admin_password'})
self.env.cr.commit()
"
    ynh_exec_as_app $bin_file shell -c "$conf_file" -d "$app" <<< \
"
self.write({'tz':'$tz','lang':'$lang'})
self.env.cr.commit()
"
    ynh_exec_as_app $bin_file shell -c "$conf_file" -d "$app" <<< \
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
    ynh_configure server.conf "$conf_file"
    chown "$app:$app" "$conf_file"
}

ynh_configure () {
	local TEMPLATE=$1
	local DEST=$2
	content=""
	content2=""
	content3=""
	if [[ $preinstall == '1' ]]; then
		content="dbfilter = $db_name"
	else
		content="db_name = $db_name"
		if [[ $app_version -gt 9 ]]; then
			content2="dbfilter = False"
		fi
		content3="list_db = False"
	fi

	ynh_config_add --template="$TEMPLATE" --destination="$DEST"
}

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
		ynh_print_warn "The main mountpoint of your system '/' is on an SD card, swap will not be added to prevent some damage of this one, but that can cause troubles for the app $app. If you still want activate the swap, you can relaunch the command preceded by 'SD_CARD_CAN_SWAP=1'"
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
