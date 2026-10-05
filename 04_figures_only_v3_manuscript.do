/****************************************************************************************
RWJF / County Health Rankings Housing and Mental Health Project
FIGURES-ONLY DO-FILE — MANUSCRIPT / COAUTHOR LAYOUT
Version: 2026-08-26-v3

Purpose
  Re-create publication-quality figures from the frozen analysis-ready dataset.
  This file does not clean data, redefine samples, save data, or change any model.

Outputs
  1. Stand-alone Figure 1A and Figure 1B files.
  2. A manuscript-friendly vertical composite with additional spacing and shorter
     axis titles, designed to be inserted at approximately 6.5 inches wide in Word.
  3. A supplementary pathway-proxy figure with complete terminology.

Important
  - Frozen sample flags are used directly.
  - Expected samples: 8,843 poor mental health observations and 7,249 suicide
    mortality observations.
  - Figure formatting changes do not reopen the statistical code freeze.
****************************************************************************************/

version 18
clear all
set more off
set varabbrev off
set linesize 255
capture log close

********************************************************************************
* 0. PROJECT PATHS
********************************************************************************

* Change only this path if the project is moved.
global root "/Users/chuyi/Library/CloudStorage/GoogleDrive-chuyiinclaremont@gmail.com/.shortcut-targets-by-id/12-9WcpPipBnCJfhgXA2Agu0tixW37IlJ/Academia Related/SchullerProject/Data_Results"

global processed "$root/1.processed_data"
global freeze_tag "2026_08_25"
global analysis_file "$processed/rwjf_2023_2025_analysis_ready_FREEZE_$freeze_tag.dta"
global output_parent "$root/3.output/FREEZE_CANDIDATE_$freeze_tag"
global output "$output_parent/figures_only_v3_manuscript"

capture mkdir "$output_parent"
capture mkdir "$output"

log using "$output/04_figures_only_v3_manuscript.log", text replace

********************************************************************************
* 1. LOAD AND VERIFY THE FROZEN DATASET
********************************************************************************

capture confirm file "$analysis_file"
if _rc {
    di as error "Frozen analysis file not found:"
    di as error "$analysis_file"
    exit 601
}

use "$analysis_file", clear

local required_vars ///
    fipscode year mental_health suicide_rate ///
    severe_housing_cost_burden_pp pct_overcrowding_pp ///
    pct_lack_necessities_pp long_commute_pp homeownership_pp ///
    pct_over65_pp pct_under18_pp pct_female_pp ///
    pct_black_pp pct_white_pp pct_hispanic_pp ///
    median_income unemployment_pp child_poverty_pp pct_rural_pp ///
    hs_completion_pp some_college_pp uninsured_pp mh_providers_1000 ///
    food_insecurity_pp insufficient_sleep_pp loneliness_pp ///
    lack_social_support_pp sample_mh sample_suicide ///
    sample_food sample_sleep sample_loneliness sample_support

foreach v of local required_vars {
    capture confirm variable `v'
    if _rc {
        di as error "Required frozen variable `v' is missing."
        exit 111
    }
}

isid fipscode year

quietly count if sample_mh == 1
local N_mh = r(N)
quietly count if sample_suicide == 1
local N_sui = r(N)
quietly count if sample_food == 1
local N_food = r(N)
quietly count if sample_sleep == 1
local N_sleep = r(N)
quietly count if sample_loneliness == 1
local N_lonely = r(N)
quietly count if sample_support == 1
local N_support = r(N)

di as result "Frozen sample check:"
di as result "  Poor mental health days = `N_mh'"
di as result "  Suicide mortality       = `N_sui'"
di as result "  Food insecurity proxy   = `N_food'"
di as result "  Insufficient sleep      = `N_sleep'"
di as result "  Loneliness              = `N_lonely'"
di as result "  Lack social support     = `N_support'"

assert `N_mh' == 8843
assert `N_sui' == 7249

********************************************************************************
* 2. MODEL DEFINITIONS — IDENTICAL TO THE FROZEN ANALYSIS
********************************************************************************

global housing_pp ///
    severe_housing_cost_burden_pp ///
    pct_overcrowding_pp ///
    pct_lack_necessities_pp ///
    long_commute_pp ///
    homeownership_pp

global controls_pp ///
    pct_over65_pp pct_under18_pp pct_female_pp ///
    pct_black_pp pct_white_pp pct_hispanic_pp ///
    median_income unemployment_pp child_poverty_pp pct_rural_pp ///
    hs_completion_pp some_college_pp uninsured_pp mh_providers_1000

capture which coefplot
if _rc {
    di as text "coefplot is not installed. Attempting SSC installation..."
    capture noisily ssc install coefplot, replace
}

capture which coefplot
if _rc {
    di as error "coefplot is required but unavailable."
    exit 499
}

********************************************************************************
* 3. ESTIMATE THE TWO FROZEN MUTUALLY ADJUSTED MODELS
********************************************************************************

quietly reg mental_health $housing_pp $controls_pp i.year ///
    if sample_mh == 1, vce(cluster fipscode)
estimates store fig_mh

quietly reg suicide_rate $housing_pp $controls_pp i.year ///
    if sample_suicide == 1, vce(cluster fipscode)
estimates store fig_sui

********************************************************************************
* 4. STAND-ALONE FIGURE 1A — POOR MENTAL HEALTH DAYS
********************************************************************************

coefplot fig_mh, ///
    keep(severe_housing_cost_burden_pp pct_overcrowding_pp ///
         pct_lack_necessities_pp long_commute_pp homeownership_pp) ///
    coeflabels( ///
        severe_housing_cost_burden_pp = "Severe housing cost burden" ///
        pct_overcrowding_pp = "Overcrowding" ///
        pct_lack_necessities_pp = "Lack of kitchen or plumbing facilities" ///
        long_commute_pp = "Long commuting" ///
        homeownership_pp = "Homeownership") ///
    xline(0, lpattern(dash)) ///
    xscale(range(-.02 .02)) ///
    xlabel(-.02 -.01 0 .01 .02, format(%4.2f) labsize(medsmall)) ///
    xtitle("Adjusted difference in poor mental health days" ///
           "per 1-percentage-point higher housing exposure", size(medsmall)) ///
    ylabel(, labsize(medsmall) angle(horizontal)) ///
    title("A. Poor Mental Health Days", size(large)) ///
    ciopts(recast(rcap)) ///
    msymbol(O) ///
    legend(off) ///
    graphregion(color(white) margin(medsmall)) ///
    plotregion(margin(medsmall)) ///
    xsize(11) ysize(6) ///
    name(Figure1A_standalone, replace)

graph save "$output/Figure1A_poor_mental_health_days.gph", replace
graph export "$output/Figure1A_poor_mental_health_days.png", replace width(3200)
graph export "$output/Figure1A_poor_mental_health_days.tif", replace width(3200)
capture noisily graph export "$output/Figure1A_poor_mental_health_days.pdf", replace
capture noisily graph export "$output/Figure1A_poor_mental_health_days.svg", replace

********************************************************************************
* 5. STAND-ALONE FIGURE 1B — AGE-ADJUSTED SUICIDE MORTALITY
********************************************************************************

coefplot fig_sui, ///
    keep(severe_housing_cost_burden_pp pct_overcrowding_pp ///
         pct_lack_necessities_pp long_commute_pp homeownership_pp) ///
    coeflabels( ///
        severe_housing_cost_burden_pp = "Severe housing cost burden" ///
        pct_overcrowding_pp = "Overcrowding" ///
        pct_lack_necessities_pp = "Lack of kitchen/plumbing facilities" ///
        long_commute_pp = "Long commuting" ///
        homeownership_pp = "Homeownership") ///
    xline(0, lpattern(dash)) ///
    xscale(range(-.2 .8)) ///
    xlabel(-.2 0 .2 .4 .6 .8, format(%3.1f) labsize(medsmall)) ///
    xtitle("Adjusted difference in suicide deaths per 100,000" ///
           "per 1-percentage-point higher housing exposure", size(medsmall)) ///
    ylabel(, labsize(medsmall) angle(horizontal)) ///
    title("B. Age-Adjusted Suicide Mortality", size(large)) ///
    ciopts(recast(rcap)) ///
    msymbol(O) ///
    legend(off) ///
    graphregion(color(white) margin(medsmall)) ///
    plotregion(margin(medsmall)) ///
    xsize(11) ysize(6) ///
    name(Figure1B_standalone, replace)

graph save "$output/Figure1B_suicide_mortality.gph", replace
graph export "$output/Figure1B_suicide_mortality.png", replace width(3200)
graph export "$output/Figure1B_suicide_mortality.tif", replace width(3200)
capture noisily graph export "$output/Figure1B_suicide_mortality.pdf", replace
capture noisily graph export "$output/Figure1B_suicide_mortality.svg", replace

********************************************************************************
* 6. COMPACT PANELS USED ONLY FOR THE MANUSCRIPT COMPOSITE
********************************************************************************

* These duplicate the frozen estimates but use smaller titles and shorter axis
* wording so the two panels fit cleanly on one manuscript page.

coefplot fig_mh, ///
    keep(severe_housing_cost_burden_pp pct_overcrowding_pp ///
         pct_lack_necessities_pp long_commute_pp homeownership_pp) ///
    coeflabels( ///
        severe_housing_cost_burden_pp = "Severe housing cost burden" ///
        pct_overcrowding_pp = "Overcrowding" ///
        pct_lack_necessities_pp = "Lack of kitchen/plumbing facilities" ///
        long_commute_pp = "Long commuting" ///
        homeownership_pp = "Homeownership") ///
    xline(0, lpattern(dash)) ///
    xscale(range(-.02 .02)) ///
    xlabel(-.02 -.01 0 .01 .02, format(%4.2f) labsize(small)) ///
    xtitle("Adjusted difference in poor mental health days" ///
           "per 1-percentage-point higher exposure", size(small)) ///
    ylabel(, labsize(small) angle(horizontal)) ///
    title("A. Poor Mental Health Days", size(medlarge) margin(small)) ///
    ciopts(recast(rcap)) ///
    msymbol(O) ///
    legend(off) ///
    graphregion(color(white) margin(medsmall)) ///
    plotregion(margin(small)) ///
    name(Figure1A_compact, replace)

coefplot fig_sui, ///
    keep(severe_housing_cost_burden_pp pct_overcrowding_pp ///
         pct_lack_necessities_pp long_commute_pp homeownership_pp) ///
    coeflabels( ///
        severe_housing_cost_burden_pp = "Severe housing cost burden" ///
        pct_overcrowding_pp = "Overcrowding" ///
        pct_lack_necessities_pp = "Lack of kitchen/plumbing facilities" ///
        long_commute_pp = "Long commuting" ///
        homeownership_pp = "Homeownership") ///
    xline(0, lpattern(dash)) ///
    xscale(range(-.2 .8)) ///
    xlabel(-.2 0 .2 .4 .6 .8, format(%3.1f) labsize(small)) ///
    xtitle("Adjusted difference in suicide deaths per 100,000" ///
           "per 1-percentage-point higher exposure", size(small)) ///
    ylabel(, labsize(small) angle(horizontal)) ///
    title("B. Age-Adjusted Suicide Mortality", size(medlarge) margin(small)) ///
    ciopts(recast(rcap)) ///
    msymbol(O) ///
    legend(off) ///
    graphregion(color(white) margin(medsmall)) ///
    plotregion(margin(small)) ///
    name(Figure1B_compact, replace)

********************************************************************************
* 7. MANUSCRIPT-FRIENDLY COMBINED MAIN FIGURE
********************************************************************************

* No overall title is embedded. Put the full Figure 1 title and legend in Word.
* The larger vertical canvas and medium inter-panel margin prevent Panel A's
* x-axis title from colliding with Panel B's title.

graph combine Figure1A_compact Figure1B_compact, ///
    cols(1) ///
    xsize(12.5) ysize(15) ///
    imargin(medium) ///
    graphregion(color(white) margin(medsmall)) ///
    name(Figure1_Combined_manuscript, replace)

graph save "$output/Figure1_Combined_for_manuscript.gph", replace
graph export "$output/Figure1_Combined_for_manuscript.png", replace width(3600)
graph export "$output/Figure1_Combined_for_manuscript.tif", replace width(3600)
capture noisily graph export "$output/Figure1_Combined_for_manuscript.pdf", replace
capture noisily graph export "$output/Figure1_Combined_for_manuscript.svg", replace

********************************************************************************
* 8. SUPPLEMENTARY PATHWAY-PROXY FIGURE
********************************************************************************

quietly reg food_insecurity_pp severe_housing_cost_burden_pp ///
    $controls_pp i.year if sample_food == 1, vce(cluster fipscode)
estimates store fig_food

quietly reg insufficient_sleep_pp long_commute_pp ///
    $controls_pp i.year if sample_sleep == 1, vce(cluster fipscode)
estimates store fig_sleep

quietly reg loneliness_pp pct_overcrowding_pp ///
    $controls_pp i.year if sample_loneliness == 1, vce(cluster fipscode)
estimates store fig_lonely

quietly reg lack_social_support_pp pct_lack_necessities_pp ///
    $controls_pp i.year if sample_support == 1, vce(cluster fipscode)
estimates store fig_support

coefplot ///
    (fig_food, keep(severe_housing_cost_burden_pp) label("Food insecurity")) ///
    (fig_sleep, keep(long_commute_pp) label("Insufficient sleep")) ///
    (fig_lonely, keep(pct_overcrowding_pp) label("Loneliness")) ///
    (fig_support, keep(pct_lack_necessities_pp) ///
        label("Lack of social or emotional support")), ///
    coeflabels( ///
        severe_housing_cost_burden_pp = "Severe housing cost burden" ///
        long_commute_pp = "Long commuting" ///
        pct_overcrowding_pp = "Overcrowding" ///
        pct_lack_necessities_pp = "Lack of kitchen/plumbing facilities") ///
    xline(0, lpattern(dash)) ///
    xscale(range(-.10 .15)) ///
    xlabel(-.10 -.05 0 .05 .10 .15, format(%4.2f) labsize(medsmall)) ///
    xtitle("Adjusted difference in pathway-proxy outcome" ///
    "per 1-percentage-point higher housing exposure", size(medsmall)) ///
    ylabel(, labsize(medsmall) angle(horizontal)) ///
    title("Supplementary Pathway-Proxy Analyses", size(large)) ///
    legend(position(6) cols(2) size(vsmall) region(lstyle(none))) ///
    note("Associational county-level models; not causal mediation.", size(vsmall)) ///
    ciopts(recast(rcap)) ///
    msymbol(O) ///
    graphregion(color(white) margin(medsmall)) ///
    plotregion(margin(medsmall)) ///
    xsize(11) ysize(7.5) ///
    name(FigureS1, replace)

graph save "$output/FigureS1_pathway_proxy_coefficients.gph", replace
graph export "$output/FigureS1_pathway_proxy_coefficients.png", replace width(3200)
graph export "$output/FigureS1_pathway_proxy_coefficients.tif", replace width(3200)
capture noisily graph export "$output/FigureS1_pathway_proxy_coefficients.pdf", replace
capture noisily graph export "$output/FigureS1_pathway_proxy_coefficients.svg", replace

********************************************************************************
* 9. FINISH
********************************************************************************

di as text "=============================================================="
di as result "FIGURES-ONLY V3 MANUSCRIPT RUN COMPLETED SUCCESSFULLY"
di as result "Output folder: $output"
di as result "For the coauthor manuscript, insert:"
di as result "  Figure1_Combined_for_manuscript.png"
di as result "For final journal upload, retain the separate A and B files as well."
di as text "=============================================================="

log close
exit
