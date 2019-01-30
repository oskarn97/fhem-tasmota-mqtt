##############################################
#
# fhem xiaomi bridge to mqtt (see http://mqtt.org)
#
# written 2018 by Oskar Neumann
# thanks to Matthias Kleine
#
##############################################

use strict;
use warnings;

sub TasmotaMQTTDevice_Initialize($) {
    my $hash = shift @_;

    # Consumer
    $hash->{DefFn} = "TasmotaMQTT::DEVICE::Define";
    $hash->{UndefFn} = "TasmotaMQTT::DEVICE::Undefine";
    $hash->{SetFn} = "TasmotaMQTT::DEVICE::Set";
    #$hash->{GetFn} = "TasmotaMQTT::DEVICE::Get";
    $hash->{AttrFn} = "TasmotaMQTT::DEVICE::Attr";
    $hash->{AttrList} = "IODev qos retain " . $main::readingFnAttributes;
    $hash->{OnMessageFn} = "TasmotaMQTT::DEVICE::onmessage";

    main::LoadModule("MQTT");
    main::LoadModule("MQTT_DEVICE");
}

package TasmotaMQTT::DEVICE;

use strict;
use warnings;
use POSIX;
use SetExtensions;
use GPUtils qw(:all);

use Net::MQTT::Constants;
use JSON;


BEGIN {
    MQTT->import(qw(:all));

    GP_Import(qw(
        CommandDeleteReading
        CommandAttr
        readingsSingleUpdate
        readingsBulkUpdate
        readingsBeginUpdate
        readingsEndUpdate
        readingsBulkUpdateIfChanged
        Log3
        fhem
        defs
        AttrVal
        ReadingsVal
    ))
};

sub Define() {
    my ($hash, $def) = @_;
    my @args = split("[ \t]+", $def);
    return "Invalid number of arguments: define <name> TasmotaMQTTDevice <topic>" if (int(@args) < 1);
    my ($name, $type, $topic) = @args;

    $hash->{TYPE} = 'MQTT_DEVICE';
    MQTT::Client_Define($hash, $def);
    $hash->{TYPE} = $type;
    $main::modules{TasmotaMQTTDevice}{defptr}{$topic} = $hash;

    $hash->{topic} = $topic;
    SubscribeReadings($hash);

    $main::attr{$name}{webCmd} =  "on:off:toggle";
    $main::attr{$name}{stateFormat} =  "power";

    $hash->{'.autoSubscribeExpr'} = "\$a"; #never auto subscribe to anything, prevents log messages
    return undef;
};

sub Attr($$$$) {
    my ($command, $name, $attribute, $value) = @_;
    my $hash = $defs{$name};

    my $result = MQTT::DEVICE::Attr($command, $name, $attribute, $value);

    if ($attribute eq "IODev") {
        #SubscribeReadings($hash);
    }

    return $result;
}

sub SubscribeReadings {
    my ($hash) = @_;
    my ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr('tele/'. $hash->{topic} .'/SENSOR');
    client_subscribe_topic($hash, $mtopic, $mqos, $mretain);

    ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr('tele/'. $hash->{topic} . '/STATE');
    client_subscribe_topic($hash, $mtopic, $mqos, $mretain);

    ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr('stat/'. $hash->{topic} . '/RESULT');
    client_subscribe_topic($hash, $mtopic, $mqos, $mretain);

    ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr('tele/'. $hash->{topic} . '/SENSOR');
    client_subscribe_topic($hash, $mtopic, $mqos, $mretain);
}

sub Undefine($$) {
    my ($hash, $name) = @_;

    client_unsubscribe_topic($hash, 'tele/'. $hash->{topic} .'/SENSOR');
    client_unsubscribe_topic($hash, 'tele/'. $hash->{topic} .'/STATE');
    client_unsubscribe_topic($hash, 'stat/'. $hash->{topic} .'/RESULT');
    client_unsubscribe_topic($hash, 'tele/'. $hash->{topic} .'/SENSOR');

    delete($main::modules{TasmotaMQTTDevice}{defptr}{$hash->{topic}});
    return MQTT::Client_Undefine($hash);
}

sub Set($$$@) {
    my ($hash, $name, $command, @values) = @_;

    if ($command eq '?') {
        my $cmdList = "on:noArg off:noArg toggle:noArg";
        return "Unknown argument " . $command . ", choose one of ". $cmdList;
    }
    
    Log3($hash->{NAME}, 5, "set " . $command . " - value: " . join (" ", @values));

    my $value = join (" ", @values);
    my $values = @values;

    $hash->{".lastSet"} = main::gettimeofday();
    publish($hash, 'cmnd/'. $hash->{topic} .'/POWER', $command);
}

sub Get($$$@) {
    my ($hash, $name, $command, @values) = @_;

    #if ($command eq '?') {
    #    return "Unknown argument " . $command . ", choose one of " . join(" ", map { "$_$gets{$_}" } keys %gets) . " " . join(" ", map {$hash->{gets}->{$_} eq "" ? $_ : "$_:".$hash->{gets}->{$_}} sort keys %{$hash->{gets}});
    #}
}

sub onmessage($$$) {
    my ($hash, $topic, $message) = @_;

    Log3($hash->{NAME}, 5, "received message '" . $message . "' for topic: " . $topic);
    my @parts = split('/', $topic);

    TasmotaMQTT::DEVICE::Decode($hash, $message, $topic);
}

sub Decode {
    my ($hash, $value, $topic) = @_;
    my $h;

    eval {
        $h = JSON::decode_json($value);
        1;
    };

    if ($@) {
        Log3($hash->{NAME}, 2, "bad JSON: $value - $@");
        return undef;
    }

    readingsBeginUpdate($hash);    
    TasmotaMQTT::DEVICE::Expand($hash, $h, "", "");

    if(defined $topic) {   
        my @parts = split('/', $topic);
        my $path = $parts[-1];

        if($path eq "RESULT" && defined $h->{POWER}) {
            if(main::gettimeofday() - $hash->{".lastSet"} > 1.5) {
                readingsBulkUpdate($hash, "manual", lc $h->{POWER});
                readingsBulkUpdate($hash, "last_on_manual", time()) if(lc $h->{POWER} eq "on");
                readingsBulkUpdate($hash, "last_off_manual", time()) if(lc $h->{POWER} eq "off");
            }
            readingsBulkUpdate($hash, "last_on", time()) if(lc $h->{POWER} eq "on");
            readingsBulkUpdate($hash, "last_off", time()) if(lc $h->{POWER} eq "off");
        }
    }

    readingsEndUpdate($hash, 1);

    return undef;
}

sub Expand {
    my ($hash, $ref, $prefix, $suffix) = @_;

    $prefix = "" if (!$prefix);
    $suffix = "" if (!$suffix);
    $suffix = "_$suffix" if ($suffix);

    if (ref($ref) eq "ARRAY") {
        while (my ($key, $value) = each @{$ref}) {
            TasmotaMQTT::DEVICE::Expand($hash, $value, $prefix . sprintf("%02i", $key + 1) . "_", "");
        }
    } elsif (ref($ref) eq "HASH") {
        while (my ($key, $value) = each %{$ref}) {
            if (ref($value) && !(ref($value) =~ m/Boolean/)) {
                TasmotaMQTT::DEVICE::Expand($hash, $value, $prefix . $key . $suffix . "-", "");
            } else {
                # replace illegal characters in reading names
                (my $reading = $prefix . $key . $suffix) =~ s/[^A-Za-z\d_\.\-\/]/_/g;
                if(ref($value) =~ m/Boolean/) {
                    $value = $value ? "true" : "false";
                }

                if($reading eq "POWER") {
                    $reading = lc $reading;
                    $value = lc $value;
                    readingsBulkUpdateIfChanged($hash, 'state', $value);
                }

                readingsBulkUpdate($hash, $reading, $value);
            }
        }
    }
}

sub publish {
    my ($hash, $topic, $message) = @_;
    my $msgid = send_publish($hash->{IODev}, topic => $topic, message => $message, qos => 1, retain => 0); 
    $hash->{message_ids}->{$msgid}++ if(defined $msgid);
}

1;