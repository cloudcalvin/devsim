# Copyright 2013 Devsim LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

lappend auto_path .
package require dsSimpleDD

proc printCurrents {device cname bias} {
set ecurr [get_contact_current -contact $cname -equation ElectronContinuityEquation -device $device]
set hcurr [get_contact_current -contact $cname -equation HoleContinuityEquation -device $device]
set tcurr [expr {$ecurr+$hcurr}]                                        
puts [format "%s\t%s\t%s\t%s\t%s" $cname $bias $ecurr $hcurr $tcurr]
}
####
#### Constants
####
proc setOxideParameters {device region} {
    set q 1.6e-19
    set k 1.3806503e-23
    set eps 8.85e-14
    set T 300
    set_parameter -device $device -region $region -name "Permittivity"     -value [expr 3.9*$eps]
    set_parameter -device $device -region $region -name "ElectronCharge"   -value $q
}

proc setSiliconParameters {device region} {
    set q 1.6e-19
    set k 1.3806503e-23
    set eps 8.85e-14
    set T 300
    set_parameter -device $device -region $region -name "Permittivity"     -value [expr 11.1*$eps]
    set_parameter -device $device -region $region -name "ElectronCharge"   -value $q
    set_parameter -device $device -region $region -name "n_i" -value 1.0e10
    set_parameter -device $device -region $region -name "kT" -value [expr $eps * $T]
    set_parameter -device $device -region $region -name "V_t"   -value [expr $k*$T/$q]
    set_parameter -device $device -region $region -name "mu_n" -value 400
    set_parameter -device $device -region $region -name "mu_p" -value 200
}

proc createSolution {device region name} {
    node_solution -device $device -region $region -name $name
    edge_from_node_model -device $device -region $region -node_model $name 
}

proc createSiliconPotentialOnly {device region} {
    # require NetDoping
set ie [node_model -device $device -region $region -name "IntrinsicElectrons" \
	   -equation "n_i*exp(Potential/V_t);"]
set res [node_model -device $device -region $region -name "IntrinsicElectrons:Potential" \
	    -equation  "diff($ie, Potential);"]
# TODO optimize so res is in terms of itself
#puts "RESULT: $res"
node_model -device $device -region $region -name "IntrinsicHoles"                         -equation "n_i^2/IntrinsicElectrons;"
node_model -device $device -region $region -name "IntrinsicHoles:Potential"               -equation "diff(n_i^2/IntrinsicElectrons, Potential);"
node_model -device $device -region $region -name "IntrinsicCharge"                        -equation "IntrinsicHoles-IntrinsicElectrons + NetDoping;"
node_model -device $device -region $region -name "IntrinsicCharge:Potential"              -equation "diff(IntrinsicHoles-IntrinsicElectrons, Potential);"
node_model -device $device -region $region -name "PotentialIntrinsicNodeCharge"           -equation "-ElectronCharge*IntrinsicCharge;"
node_model -device $device -region $region -name "PotentialIntrinsicNodeCharge:Potential" -equation "diff(-ElectronCharge*IntrinsicCharge, Potential);"

edge_model -device $device -region $region -name "ElectricField"                 -equation  "(Potential@n0-Potential@n1)*EdgeInverseLength;"
edge_model -device $device -region $region -name "ElectricField:Potential@n0"     -equation "EdgeInverseLength;"
edge_model -device $device -region $region -name "ElectricField:Potential@n1"     -equation "-ElectricField:Potential@n0;"
edge_model -device $device -region $region -name "PotentialEdgeFlux"             -equation  "Permittivity*ElectricField;"
edge_model -device $device -region $region -name "PotentialEdgeFlux:Potential@n0" -equation "diff(Permittivity*ElectricField,Potential@n0);"
edge_model -device $device -region $region -name "PotentialEdgeFlux:Potential@n1" -equation "-PotentialEdgeFlux:Potential@n0;"

equation -device $device -region $region -name PotentialEquation -variable_name Potential \
	 -node_model "PotentialIntrinsicNodeCharge" -edge_model "PotentialEdgeFlux" -variable_update log_damp 
}

#proc createPotentialOnlyContact {device region contact type} {}
proc createSiliconPotentialOnlyContact {device region contact} {

node_model -device $device -region $region -name "contactcharge_node" -equation "ElectronCharge*IntrinsicCharge;"
edge_model -device $device -region $region -name "contactcharge_edge" -equation "ElectronCharge*ElectricField;"

set_parameter -device $device -region $region -name "${contact}bias" -value 0.0
#####
##### TODO: handle the case where the concentration can be negative
#####
contact_node_model -device $device -contact ${contact} -name "celec_${contact}" -equation "1e-10 + 0.5*abs(NetDoping+(NetDoping^2 + 4 * n_i^2)^(0.5));"
contact_node_model -device $device -contact ${contact} -name "chole_${contact}" -equation "1e-10 + 0.5*abs(-NetDoping+(NetDoping^2 + 4 * n_i^2)^(0.5));"

contact_node_model -device $device -contact ${contact} -name "${contact}nodemodel" -equation \
  "ifelse(NetDoping > 0, \
  Potential-${contact}bias-V_t*log(celec_${contact}/n_i), \
  Potential-${contact}bias+V_t*log(chole_${contact}/n_i));"

contact_node_model -device $device -contact ${contact} -name "${contact}nodemodel:Potential" -equation "1;"


contact_equation -device $device -contact "${contact}" -name "PotentialEquation" -variable_name Potential \
			-node_model "${contact}nodemodel" -edge_model "" \
			-node_charge_model "contactcharge_node" -edge_charge_model "contactcharge_edge" \
			-node_current_model ""   -edge_current_model ""
}

proc createSiliconDriftDiffusion {device region} {
node_model -device $device -region $region -name "PotentialNodeCharge"           -equation "-ElectronCharge*(Holes -Electrons + NetDoping);"
node_model -device $device -region $region -name "PotentialNodeCharge:Electrons" -equation "+ElectronCharge;"
node_model -device $device -region $region -name "PotentialNodeCharge:Holes"     -equation "-ElectronCharge;"

equation -device $device -region $region -name PotentialEquation -variable_name Potential -node_model "PotentialNodeCharge" \
    -edge_model "PotentialEdgeFlux" -time_node_model "" -variable_update log_damp 

createBernoulli $device $region
createElectronCurrent $device $region
createHoleCurrent $device $region

set NCharge "-ElectronCharge * Electrons"
set dNChargedn "-ElectronCharge"
node_model -device $device -region $region -name "NCharge" -equation "$NCharge;"
node_model -device $device -region $region -name "NCharge:Electrons" -equation "$dNChargedn;"

set PCharge "-ElectronCharge * Holes"
set dPChargedp "-ElectronCharge"
node_model -device $device -region $region -name "PCharge" -equation "$PCharge;"
node_model -device $device -region $region -name "PCharge:Holes" -equation "$dPChargedp;"


set ni [get_parameter -device $device -region $region -name "n_i"]
#puts "ni $ni"
set_parameter -device $device -region $region -name "n1" -value $ni
set_parameter -device $device -region $region -name "p1" -value $ni
set_parameter -device $device -region $region -name "taun" -value 1e-5
set_parameter -device $device -region $region -name "taup" -value 1e-5

set USRH "-ElectronCharge*(Electrons*Holes - n_i^2)/(taup*(Electrons + n1) + taun*(Holes + p1))"
set dUSRHdn "simplify(diff($USRH, Electrons))"
set dUSRHdp "simplify(diff($USRH, Holes))"
node_model -device $device -region $region -name "USRH" -equation "$USRH;"
node_model -device $device -region $region -name "USRH:Electrons" -equation "$dUSRHdn;"
node_model -device $device -region $region -name "USRH:Holes" -equation "$dUSRHdp;"


equation -device $device -region $region -name ElectronContinuityEquation -variable_name Electrons \
	 -edge_model "ElectronCurrent" -variable_update "positive" \
	 -time_node_model "NCharge" -node_model USRH

equation -device $device -region $region -name HoleContinuityEquation -variable_name Holes \
	 -edge_model "HoleCurrent" -variable_update "positive"  \
	 -time_node_model "PCharge" -node_model USRH
}

proc createSiliconDriftDiffusionAtContact {device region contact} {
contact_node_model -device $device -contact $contact -name "${contact}nodeelectrons"           -equation "ifelse(NetDoping > 0, Electrons - celec_${contact}, Electrons - n_i^2/chole_${contact});"
contact_node_model -device $device -contact $contact -name "${contact}nodeholes"               -equation "ifelse(NetDoping < 0, Holes - chole_${contact}, Holes - n_i^2/celec_${contact});"
contact_node_model -device $device -contact $contact -name "${contact}nodeelectrons:Electrons" -equation "1.0;"
contact_node_model -device $device -contact $contact -name "${contact}nodeholes:Holes"         -equation "1.0;"

edge_model -device $device -region $region -name "${contact}nodeelectroncurrent"     -equation "ElectronCurrent;"
contact_edge_model -device $device -contact $contact -name "${contact}nodeholecurrent"         -equation "HoleCurrent;"

contact_equation -device $device -contact $contact -name "ElectronContinuityEquation" -variable_name Electrons \
			-node_model "${contact}nodeelectrons" \
			-node_charge_model "contactcharge_node" \
			-edge_current_model "${contact}nodeelectroncurrent"

contact_equation -device $device -contact $contact -name "HoleContinuityEquation" -variable_name Holes \
			-node_model "${contact}nodeholes" \
			-node_charge_model "contactcharge_node" \
			-edge_current_model "${contact}nodeholecurrent"
}


proc createOxidePotentialOnly {device region} {
edge_model -device $device -region $region -name ElectricField \
		 -equation "(Potential@n0 - Potential@n1)*EdgeInverseLength;"

edge_model -device $device -region $region -name "ElectricField:Potential@n0" \
		 -equation "EdgeInverseLength;"

edge_model -device $device -region $region -name "ElectricField:Potential@n1" \
		 -equation "-EdgeInverseLength;"

edge_model -device $device -region $region -name PotentialEdgeFlux -equation "Permittivity*ElectricField;"
edge_model -device $device -region $region -name PotentialEdgeFlux:Potential@n0 -equation "diff(Permittivity*ElectricField, Potential@n0);"
edge_model -device $device -region $region -name PotentialEdgeFlux:Potential@n1 -equation "-PotentialEdgeFlux:Potential@n0;"

equation -device $device -region $region -name PotentialEquation -variable_name Potential -node_model "" \
    -edge_model "PotentialEdgeFlux" -time_node_model "" -variable_update log_damp 
}

proc createSiliconOxideInterface {device interface} {
interface_model -device $device -interface $interface -name continuousPotential -equation "Potential@r0-Potential@r1;"
interface_model -device $device -interface $interface -name continuousPotential:Potential@r0 -equation  "1;"
interface_model -device $device -interface $interface -name continuousPotential:Potential@r1 -equation "-1;"
interface_equation   -device $device -interface $interface -name "PotentialEquation" -variable_name "Potential" -interface_model "continuousPotential" -type "continuous"
}

#TODO: similar model for silicon/silicon interface
# should use quasi-fermi potential
proc createSiliconSiliconInterface {device interface} {
interface_model -device $device -interface $interface -name continuousPotential -equation "Potential@r0-Potential@r1;"
interface_model -device $device -interface $interface -name continuousPotential:Potential@r0 -equation  "1;"
interface_model -device $device -interface $interface -name continuousPotential:Potential@r1 -equation "-1;"
interface_equation   -device $device -interface $interface -name "PotentialEquation" -variable_name "Potential" -interface_model "continuousPotential" -type "continuous"

interface_model -device $device -interface $interface -name continuousElectrons -equation "Electrons@r0-Electrons@r1;"
interface_model -device $device -interface $interface -name continuousElectrons:Electrons@r0 -equation  "1;"
interface_model -device $device -interface $interface -name continuousElectrons:Electrons@r1 -equation "-1;"
interface_equation   -device $device -interface $interface -name "ElectronContinuityEquation" -variable_name "Electrons" -interface_model "continuousElectrons" -type continuous

interface_model -device $device -interface $interface -name continuousHoles -equation "Holes@r0-Holes@r1;"
interface_model -device $device -interface $interface -name continuousHoles:Holes@r0 -equation  "1;"
interface_model -device $device -interface $interface -name continuousHoles:Holes@r1 -equation "-1;"
interface_equation   -device $device -interface $interface -name "ElectronContinuityEquation" -variable_name "Holes" -interface_model "continuousHoles" -type continuous

}

