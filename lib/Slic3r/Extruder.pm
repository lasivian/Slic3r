package Slic3r::Extruder;
use Moo;

has 'layer'              => (is => 'rw');
has 'shift_x'            => (is => 'ro', default => sub {0} );
has 'shift_y'            => (is => 'ro', default => sub {0} );
has 'z'                  => (is => 'rw', default => sub {0} );
has 'flow_ratio'         => (is => 'rw', default => sub {1});

has 'extrusion_distance' => (is => 'rw', default => sub {0} );
has 'retracted'          => (is => 'rw', default => sub {1} );  # this spits out some plastic at start
has 'lifted'             => (is => 'rw', default => sub {0} );
has 'last_pos'           => (is => 'rw', default => sub { [0,0] } );
has 'last_f'             => (is => 'rw', default => sub {0});
has 'dec'                => (is => 'ro', default => sub { 3 } );

# calculate speeds
has 'travel_feed_rate' => (
    is      => 'ro',
    default => sub { $Slic3r::travel_feed_rate * 60 },  # mm/min
);
has 'print_feed_rate' => (
    is      => 'ro',
    default => sub { $Slic3r::print_feed_rate * 60 },  # mm/min
);
has 'perimeter_feed_rate' => (
    is      => 'ro',
    default => sub { $Slic3r::perimeter_feed_rate * 60 },  # mm/min
);
has 'retract_speed' => (
    is      => 'ro',
    default => sub { $Slic3r::retract_speed * 60 },  # mm/min
);

use Slic3r::Geometry qw(points_coincide PI X Y);
use XXX;

sub change_layer {
    my $self = shift;
    my ($layer) = @_;
    
    $self->layer($layer);
    my $z = $Slic3r::z_offset + $layer->print_z * $Slic3r::resolution;
    
    my $gcode = "";
    
    $gcode .= $self->retract(move_z => $z);
    $gcode .= $self->G0(undef, $z, 0, 'move to next layer')
        if $self->z != $z;
    
    return $gcode;
}

sub extrude_loop {
    my $self = shift;
    my ($loop, $description) = @_;
        
    # find the point of the loop that is closest to the current extruder position
    my $start_at = $loop->nearest_point_to($self->last_pos);
    
    # split the loop at the starting point and make a path
    my $extrusion_path = $loop->split_at($start_at);
    
    # clip the path to avoid the extruder to get exactly on the first point of the loop
    $extrusion_path->clip_end($Slic3r::flow_width / $Slic3r::resolution);
    
    # extrude along the path
    return $self->extrude($extrusion_path, $description);
}

sub extrude {
    my $self = shift;
    my ($path, $description, $recursive) = @_;
    
    $path->merge_continuous_lines;
    
    # detect arcs
    if ($Slic3r::gcode_arcs && !$recursive) {
        my $gcode = "";
        $gcode .= $self->extrude($_, $description, 1) for $path->detect_arcs;
        return $gcode;
    }
    
    my $gcode = "";
    
    # retract if distance from previous position is greater or equal to the one
    # specified by the user *and* to the maximum distance between infill lines
    my $distance_from_last_pos = Slic3r::Geometry::distance_between_points($self->last_pos, $path->points->[0]) * $Slic3r::resolution;
    if ($distance_from_last_pos >= $Slic3r::retract_before_travel
        && ($Slic3r::fill_density == 0 || $distance_from_last_pos >= $Slic3r::flow_width / $Slic3r::fill_density * sqrt(2))) {
        $gcode .= $self->retract(travel_to => $path->points->[0]);
    }
    
    # go to first point of extrusion path
    $gcode .= $self->G0($path->points->[0], undef, 0, "move to first $description point")
        if !points_coincide($self->last_pos, $path->points->[0]);
    
    # compensate retraction
    $gcode .= $self->unretract if $self->retracted;
    
    # calculate extrusion length per distance unit
    my $e = $Slic3r::resolution
        * (($Slic3r::nozzle_diameter**2) / ($Slic3r::filament_diameter ** 2))
        * $Slic3r::thickness_ratio 
        * $self->flow_ratio
        * $Slic3r::filament_packing_density
        * $path->depth_layers;
    
    # extrude arc or line
    if ($path->isa('Slic3r::ExtrusionPath::Arc')) {
        $gcode .= $self->G2_G3($path->points->[-1], $path->orientation, 
            $path->center, $e * $path->length, $description);
    } else {
        foreach my $line ($path->lines) {
            $gcode .= $self->G1($line->b, undef, $e * $line->length, $description);
        }
    }
    
    return $gcode;
}

sub retract {
    my $self = shift;
    my %params = @_;
    
    return "" unless $Slic3r::retract_length > 0 
        && !$self->retracted;
    
    # prepare moves
    my $retract = [undef, undef, -$Slic3r::retract_length, "retract"];
    my $lift    = ($Slic3r::retract_lift == 0)
        ? undef
        : [undef, $self->z + $Slic3r::retract_lift, 0, 'lift plate during retraction'];
    
    my $gcode = "";
    if ($Slic3r::g0 && $params{travel_to}) {
        if ($lift) {
            # combine lift and retract
            $lift->[2] = $retract->[2];
            $gcode .= $self->G0(@$lift);
        } else {
            # combine travel and retract
            my $travel = [$params{travel_to}, undef, $retract->[2], 'travel and retract'];
            $gcode .= $self->G0(@$travel);
        }
    } elsif ($Slic3r::g0 && defined $params{move_z}) {
        # combine Z change and retraction
        my $travel = [undef, $params{move_z}, $retract->[2], 'change layer and retract'];
        $gcode .= $self->G0(@$travel);
    } else {
        $gcode .= $self->G1(@$retract);
        if ($lift) {
            $gcode .= $self->G1(@$lift);
        }
    }
    $self->retracted(1);
    $self->lifted(1) if $lift;
    
    # reset extrusion distance during retracts
    # this makes sure we leave sufficient precision in the firmware
    if (!$Slic3r::use_relative_e_distances) {
        $gcode .= "G92 E0\n";
        $self->extrusion_distance(0);
    }
    
    return $gcode;
}

sub unretract {
    my $self = shift;
    $self->retracted(0);
    my $gcode = "";
    
    if ($self->lifted) {
        $gcode .= $self->G0(undef, $self->z - $Slic3r::retract_lift, 0, 'restore layer Z');
        $self->lifted(0);
    }
    
    $gcode .= $self->G0(undef, undef, ($Slic3r::retract_length + $Slic3r::retract_restart_extra), 
        "compensate retraction");
    
    return $gcode;
}

sub G0 {
    my $self = shift;
    return $self->G1(@_) if !$Slic3r::g0;
    return "G0" . $self->G0_G1(@_);
}

sub G1 {
    my $self = shift;
    return "G1" . $self->G0_G1(@_);
}

sub G0_G1 {
    my $self = shift;
    my ($point, $z, $e, $comment) = @_;
    my $dec = $self->dec;
    
    my $gcode = "";
    
    if ($point) {
        $gcode .= sprintf " X%.${dec}f Y%.${dec}f", 
            ($point->x * $Slic3r::resolution) + $self->shift_x, 
            ($point->y * $Slic3r::resolution) + $self->shift_y; #**
        $self->last_pos($point);
    }
    if (defined $z && $z != $self->z) {
        $self->z($z);
        $gcode .= sprintf " Z%.${dec}f", $z;
    }
    
    return $self->_Gx($gcode, $e, $comment);
}

sub G2_G3 {
    my $self = shift;
    my ($point, $orientation, $center, $e, $comment) = @_;
    my $dec = $self->dec;
    
    my $gcode = $orientation eq 'cw' ? "G2" : "G3";
    
    $gcode .= sprintf " X%.${dec}f Y%.${dec}f", 
        ($point->x * $Slic3r::resolution) + $self->shift_x, 
        ($point->y * $Slic3r::resolution) + $self->shift_y; #**
    
    # XY distance of the center from the start position
    $gcode .= sprintf " I%.${dec}f J%.${dec}f",
        ($center->[X] - $self->last_pos->[X]) * $Slic3r::resolution,
        ($center->[Y] - $self->last_pos->[Y]) * $Slic3r::resolution;
    
    $self->last_pos($point);
    return $self->_Gx($gcode, $e, $comment);
}

sub _Gx {
    my $self = shift;
    my ($gcode, $e, $comment) = @_;
    my $dec = $self->dec;
    
    # apply the speed reduction for print moves on bottom layer
    my $speed_multiplier = $e && $self->layer->id == 0
        ? $Slic3r::bottom_layer_speed_ratio 
        : 1;
    
    # determine speed
    my $speed = $self->travel_feed_rate * $speed_multiplier;
    if ($e) {
        $speed = $self->print_feed_rate * $speed_multiplier;
        $speed = $self->retract_speed if $comment =~ /retract/;
        $speed = $self->perimeter_feed_rate * $speed_multiplier if $comment =~ /perimeter/;
    }
    
    # output speed if it's different from last one used
    # (goal: reduce gcode size)
    if ($speed != $self->last_f) {
        $gcode .= sprintf " F%.${dec}f", $speed;
        $self->last_f($speed);
    }
    
    # output extrusion distance
    if ($e && !$Slic3r::no_extrusion) {
        $self->extrusion_distance(0) if $Slic3r::use_relative_e_distances;
        $self->extrusion_distance($self->extrusion_distance + $e);
        $gcode .= sprintf " E%.5f", $self->extrusion_distance;
    }
    
    $gcode .= sprintf " ; %s", $comment if $comment;
    return "$gcode\n";
}

1;