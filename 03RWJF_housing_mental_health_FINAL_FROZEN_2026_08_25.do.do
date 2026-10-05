/****************************************************************************************
RWJF / County Health Rankings Housing and Mental Health Project
FINAL MERGED ANALYSIS + REVIEWER-QA DO-FILE — FREEZE CANDIDATE
Version: 2026-08-25

This single do-file replaces:
  - 2.analysis_v2.do
  - 3.analysis_QA.do

PHASE I
  Clean and append 2023–2025 CHR&R releases; restrict to county/county-equivalent
  records; construct variables and common outcome-specific samples; estimate main,
  robustness, heterogeneity, and housing-to-pathway-proxy models; create tables/figures.

PHASE II
  Run reviewer-driven sample-selection comparisons, sequential adjustment models,
  common-sample pathway-adjusted outcome models, correlation matrices, and VIF checks.

IMPORTANT HOUSEKEEPING DECISIONS
  - Outputs are written to a new versioned folder so old-N tables cannot be mixed with
    the corrected results.
  - The obsolete pathway-adjustment tables that compared different samples have been
    removed. Only common-sample pathway comparisons are generated.
  - Two logs are produced: 01_main_analysis.log and 02_reviewer_QA.log.
  - A successful run ends with "CODE FREEZE CHECKS PASSED" and writes
    ANALYSIS_FREEZE_MANIFEST.txt.

****************************************************************************************/

version 18
clear all
set more off
set varabbrev off
set linesize 255
capture log close

********************************************************************************
* 0. USER PATH, VERSION, AND RUN CONFIGURATION
********************************************************************************

* Change only this project root path if needed.
global root "/Users/chuyi/Library/CloudStorage/GoogleDrive-chuyiinclaremont@gmail.com/.shortcut-targets-by-id/12-9WcpPipBnCJfhgXA2Agu0tixW37IlJ/Academia Related/SchullerProject/Data_Results"

global raw       "$root/0.raw_data"
global processed "$root/1.processed_data"

* New clean output directory; old files in $root/3.output remain untouched.
global freeze_tag "2026_08_25"
global output_parent "$root/3.output"
global output "$output_parent/FREEZE_CANDIDATE_$freeze_tag"

global analysis_file "$processed/rwjf_2023_2025_analysis_ready_FREEZE_$freeze_tag.dta"

* Optional SDI files.
global sdi_dta "$raw/sdi_county.dta"
global sdi_csv "$raw/sdi_county.csv"

* Run switches. Keep these values for the freeze run.
global RUN_VERBOSE_DESCRIPTIVES 0
global RUN_CHILD_INTERACTIONS   0
global RUN_FIGURES              1
global STRICT_FREEZE_CHECKS     1

* Expected counts for the fixed 2023–2025 CHR&R release files.
global EXPECTED_TOTAL       9437
global EXPECTED_MH_OBSERVED 9427
global EXPECTED_SUI_OBSERVED 7308
global EXPECTED_MH_FINAL    8843
global EXPECTED_SUI_FINAL   7249

capture mkdir "$processed"
capture mkdir "$output_parent"
capture mkdir "$output"
cd "$processed"

log using "$output/01_main_analysis.log", text replace

di "Analysis version: $freeze_tag"
di "Output directory: $output"

********************************************************************************
* 0A. REQUIRED COMMUNITY-CONTRIBUTED PACKAGES
********************************************************************************

foreach pkg in eststo esttab coefplot {
    capture which `pkg'
    if _rc {
        if inlist("`pkg'", "eststo", "esttab") {
            di as text "estout package not found. Attempting SSC installation..."
            capture noisily ssc install estout, replace
        }
        else {
            di as text "coefplot not found. Attempting SSC installation..."
            capture noisily ssc install coefplot, replace
        }
    }
    capture which `pkg'
    if _rc {
        di as error "Required command `pkg' is unavailable. Installation failed."
        error 499
    }
}

********************************************************************************
* 1. OPTIONAL: IMPORT CSV FILES
********************************************************************************
* Uncomment and edit if starting from CSV files.
*
* import delimited "$raw/analytic_data2023.csv", clear
* save "$processed/analytic_data2023_rwjf.dta", replace
*
* import delimited "$raw/analytic_data2024.csv", clear
* save "$processed/analytic_data2024_rwjf.dta", replace
*
* import delimited "$raw/analytic_data2025_v2.csv", clear
* save "$processed/analytic_data2025_rwjf.dta", replace


********************************************************************************
* 2. CLEAN EACH YEAR AND APPEND
********************************************************************************

local years 2023 2024 2025
local first = 1

* Store annual geographic restrictions for transparent sample derivation.
tempname geoaudit
tempfile geoaudit_data
postfile `geoaudit' int release_year long records_loaded long noncounty_rows ///
    long territory_rows long county_rows_retained using `geoaudit_data', replace

foreach y of local years {

    di "=================================================================="
    di "Cleaning CHR&R analytic data for `y'"
    di "=================================================================="

    use "$processed/analytic_data`y'_rwjf.dta", clear

    * Keep identifiers first. Geographic identifiers are required because the
    * CHR&R analytic files also contain state and national aggregate rows.
    capture confirm variable state
    if _rc gen str30 state = ""
    capture confirm variable county
    if _rc gen str80 county = ""

    capture confirm variable statecode
    if _rc {
        di as error "Required variable statecode is missing from the `y' analytic file."
        error 111
    }
    capture confirm variable countycode
    if _rc {
        di as error "Required variable countycode is missing from the `y' analytic file."
        error 111
    }
    capture confirm variable fipscode
    if _rc {
        di as error "Required variable fipscode is missing from the `y' analytic file."
        error 111
    }

    * Harmonize identifiers to numeric form when imported as strings.
    foreach id in statecode countycode fipscode {
        capture confirm numeric variable `id'
        if _rc destring `id', replace force
    }

    * Use the CHR&R release year explicitly rather than any source-year field.
    capture drop year
    gen int year = `y'

    * Restrict to county/county-equivalent rows. State and national aggregate rows
    * have countycode equal to zero or missing. Exclude U.S. territories because
    * the study population is the 50 states and District of Columbia.
    quietly count
    local n_loaded = r(N)

    quietly count if missing(countycode) | countycode == 0
    local n_noncounty = r(N)
    drop if missing(countycode) | countycode == 0

    quietly count if missing(statecode) | inlist(statecode, 60, 66, 69, 72, 78)
    local n_territory = r(N)
    drop if missing(statecode) | inlist(statecode, 60, 66, 69, 72, 78)

    quietly count
    local n_county = r(N)

    post `geoaudit' (`y') (`n_loaded') (`n_noncounty') (`n_territory') (`n_county')

    di as text "`y' geography audit: loaded=" `n_loaded' ///
        ", noncounty removed=" `n_noncounty' ///
        ", territory removed=" `n_territory' ///
        ", county rows retained=" `n_county'

    * Required main-analysis variables must exist in every release.
    * Optional social-pathway variables (v183/v184) are checked separately below.
    local required_raw_vars ///
        v052_rawvalue v053_rawvalue v057_rawvalue ///
        v054_rawvalue v055_rawvalue v056_rawvalue v081_rawvalue v126_rawvalue ///
        v168_rawvalue v069_rawvalue ///
        v063_rawvalue v023_rawvalue v024_rawvalue v058_rawvalue ///
        v136_rawvalue v136_other_data_1 v136_other_data_2 v136_other_data_3 ///
        v154_rawvalue v137_rawvalue v153_rawvalue ///
        v085_rawvalue v062_rawvalue ///
        v042_rawvalue v161_rawvalue ///
        v139_rawvalue v143_rawvalue

    foreach v of local required_raw_vars {
        capture confirm variable `v'
        if _rc {
            di as error "Required variable `v' is missing from the `y' CHR&R release file."
            error 111
        }
    }

    * Demographics
    capture confirm variable v052_rawvalue
    if !_rc gen pct_under18 = v052_rawvalue
    else gen pct_under18 = .

    capture confirm variable v053_rawvalue
    if !_rc gen pct_over65 = v053_rawvalue
    else gen pct_over65 = .

    capture confirm variable v057_rawvalue
    if !_rc gen pct_female = v057_rawvalue
    else gen pct_female = .

    capture confirm variable v054_rawvalue
    if !_rc gen pct_black = v054_rawvalue
    else gen pct_black = .

    capture confirm variable v055_rawvalue
    if !_rc gen pct_ai = v055_rawvalue
    else gen pct_ai = .

    capture confirm variable v056_rawvalue
    if !_rc gen pct_hispanic = v056_rawvalue
    else gen pct_hispanic = .

    capture confirm variable v081_rawvalue
    if !_rc gen pct_asian = v081_rawvalue
    else gen pct_asian = .

    capture confirm variable v126_rawvalue
    if !_rc gen pct_white = v126_rawvalue
    else gen pct_white = .

    * Education
    * Use adult high school completion (v168) rather than cohort graduation (v021).
    * v168 provides a county-level educational-attainment measure with broader,
    * more comparable coverage across states.
    capture confirm variable v168_rawvalue
    if _rc {
        di as error "Required variable v168_rawvalue (high school completion) is missing from the `y' analytic file."
        error 111
    }
    gen hs_completion = v168_rawvalue

    capture confirm variable v069_rawvalue
    if !_rc gen some_college = v069_rawvalue
    else gen some_college = .

    * Socioeconomic controls
    capture confirm variable v063_rawvalue
    if !_rc gen median_income = v063_rawvalue
    else gen median_income = .

    capture confirm variable v023_rawvalue
    if !_rc gen unemployment = v023_rawvalue
    else gen unemployment = .

    capture confirm variable v024_rawvalue
    if !_rc gen child_poverty = v024_rawvalue
    else gen child_poverty = .

    capture confirm variable v058_rawvalue
    if !_rc gen pct_rural = v058_rawvalue
    else gen pct_rural = .

    * Housing exposures
    capture confirm variable v136_rawvalue
    if !_rc gen severe_housing = v136_rawvalue
    else gen severe_housing = .

    capture confirm variable v136_other_data_1
    if !_rc gen pct_high_housing_cost = v136_other_data_1
    else gen pct_high_housing_cost = .

    capture confirm variable v136_other_data_2
    if !_rc gen pct_overcrowding = v136_other_data_2
    else gen pct_overcrowding = .

    capture confirm variable v136_other_data_3
    if !_rc gen pct_lack_necessities = v136_other_data_3
    else gen pct_lack_necessities = .

    capture confirm variable v154_rawvalue
    if !_rc gen severe_housing_cost_burden = v154_rawvalue
    else gen severe_housing_cost_burden = .

    capture confirm variable v137_rawvalue
    if !_rc gen long_commute = v137_rawvalue
    else gen long_commute = .

    capture confirm variable v153_rawvalue
    if !_rc gen homeownership = v153_rawvalue
    else gen homeownership = .

    * Insurance and health care supply
    capture confirm variable v085_rawvalue
    if !_rc gen uninsured = v085_rawvalue
    else gen uninsured = .

    capture confirm variable v003_rawvalue
    if !_rc gen uninsured_adults = v003_rawvalue
    else gen uninsured_adults = .

    capture confirm variable v122_rawvalue
    if !_rc gen uninsured_children = v122_rawvalue
    else gen uninsured_children = .

    capture confirm variable v062_rawvalue
    if !_rc gen mh_providers = v062_rawvalue
    else gen mh_providers = .

    * Main outcomes
    capture confirm variable v042_rawvalue
    if !_rc gen mental_health = v042_rawvalue
    else gen mental_health = .

    * Suicide outcome: use age-adjusted suicide mortality only.
    * CHR&R data dictionary: v161_rawvalue = Suicides raw value.
    * Do NOT use v161_other_data_1 here because it is the crude suicide rate.
    capture confirm variable v161_rawvalue
    if !_rc gen suicide_rate = v161_rawvalue
    else gen suicide_rate = .

    capture confirm variable v161_numerator
    if !_rc gen suicide_numerator = v161_numerator
    else gen suicide_numerator = .

    capture confirm variable v161_denominator
    if !_rc gen suicide_denominator = v161_denominator
    else gen suicide_denominator = .

    * Added pathway-proxy measures to strengthen paper
    * Material hardship
    capture confirm variable v139_rawvalue
    if !_rc gen food_insecurity = v139_rawvalue
    else gen food_insecurity = .

    * Time scarcity / stress / environmental pathway
    capture confirm variable v143_rawvalue
    if !_rc gen insufficient_sleep = v143_rawvalue
    else gen insufficient_sleep = .

    * Social isolation / social support pathway
    capture confirm variable v183_rawvalue
    if !_rc gen loneliness = v183_rawvalue
    else gen loneliness = .

    capture confirm variable v184_rawvalue
    if !_rc gen lack_social_support = v184_rawvalue
    else gen lack_social_support = .

    capture confirm variable v140_rawvalue
    if !_rc gen social_associations = v140_rawvalue
    else gen social_associations = .

    keep state county year statecode countycode fipscode ///
         pct_under18 pct_over65 pct_female pct_black pct_ai pct_hispanic pct_asian pct_white ///
         hs_completion some_college median_income unemployment child_poverty pct_rural ///
         severe_housing pct_high_housing_cost pct_overcrowding pct_lack_necessities ///
         severe_housing_cost_burden long_commute homeownership ///
         uninsured uninsured_adults uninsured_children mh_providers ///
         mental_health suicide_rate suicide_numerator suicide_denominator ///
         food_insecurity insufficient_sleep loneliness lack_social_support social_associations

    compress
    save "$processed/cleaned_`y'_rwjf.dta", replace

    if `first' == 1 {
        save "$processed/rwjf_2023_2025_panel.dta", replace
        local first = 0
    }
    else {
        use "$processed/rwjf_2023_2025_panel.dta", clear
        append using "$processed/cleaned_`y'_rwjf.dta"
        save "$processed/rwjf_2023_2025_panel.dta", replace
    }
}

postclose `geoaudit'

* Export the annual geography audit before loading the pooled panel.
preserve
    use `geoaudit_data', clear
    sort release_year
    save "$processed/geography_audit_2023_2025.dta", replace
    export excel using "$output/TableS0A_Geography_audit.xlsx", ///
        firstrow(variables) replace
    export delimited using "$output/TableS0A_Geography_audit.csv", replace
restore

use "$processed/rwjf_2023_2025_panel.dta", clear

* Verify one county/county-equivalent record per release year.
count if missing(fipscode)
if r(N) > 0 {
    di as error "County-only panel contains records with missing fipscode."
    list year state county statecode countycode fipscode if missing(fipscode), noobs
    error 459
}

capture isid fipscode year
if _rc {
    di as error "fipscode-year does not uniquely identify records after geographic restriction."
    duplicates report fipscode year
    duplicates list fipscode year
    error 459
}

********************************************************************************
* 3. VARIABLE CONSTRUCTION
********************************************************************************

* Geographic restrictions were applied within each annual file before append.
* Confirm that only county/county-equivalent rows in the 50 states and DC remain.
assert countycode > 0 & !missing(countycode)
assert !inlist(statecode, 60, 66, 69, 72, 78) & !missing(statecode)

* Binary housing groups for descriptive and sensitivity analyses
capture drop housing_group
gen housing_group = severe_housing >= 0.20 if !missing(severe_housing)
label define housing_lbl 0 "Low Housing Problem" 1 "High Housing Problem", replace
label values housing_group housing_lbl

capture drop housing_cost_group
gen housing_cost_group = pct_high_housing_cost >= 0.20 if !missing(pct_high_housing_cost)
label define cost_lbl 0 "County prevalence <20%" 1 "County prevalence >=20%", replace
label values housing_cost_group cost_lbl

capture drop severe_cost_burden_group
gen severe_cost_burden_group = severe_housing_cost_burden >= 0.15 if !missing(severe_housing_cost_burden)
label define burdenlbl 0 "County prevalence <15%" 1 "County prevalence >=15%", replace
label values severe_cost_burden_group burdenlbl

capture drop overcrowding_group
gen overcrowding_group = pct_overcrowding > 0.05 if !missing(pct_overcrowding)
label define overcrowdlbl 0 "County prevalence <=5%" 1 "County prevalence >5%", replace
label values overcrowding_group overcrowdlbl

capture drop lack_necessities_group
gen lack_necessities_group = pct_lack_necessities > 0.01 if !missing(pct_lack_necessities)
label define lacklbl 0 "County prevalence <=1%" 1 "County prevalence >1%", replace
label values lack_necessities_group lacklbl

capture drop long_commute_group
gen long_commute_group = long_commute > 0.30 if !missing(long_commute)
label define commutelbl 0 "County prevalence <=30%" 1 "County prevalence >30%", replace
label values long_commute_group commutelbl

sum homeownership, detail
capture drop homeownership_group
gen homeownership_group = homeownership < r(p50) if !missing(homeownership)
label define ownlbl 0 "Above Median" 1 "Below Median", replace
label values homeownership_group ownlbl

* Census region
capture drop region
gen region = .
replace region = 1 if inlist(statecode, 9,23,25,33,44,50,34,36,42)
replace region = 2 if inlist(statecode, 17,18,26,39,55,19,20,27,29,31,38,46)
replace region = 3 if inlist(statecode, 10,11,12,13,24,37,45,51,54,1,21,28,47,5,22,40,48)
replace region = 4 if inlist(statecode, 4,8,16,30,32,35,49,56,2,6,15,41,53)
label define regionlbl 1 "Northeast" 2 "Midwest" 3 "South" 4 "West", replace
label values region regionlbl

********************************************************************************
* 3A. OPTIONAL: MERGE COUNTY-LEVEL SOCIAL DEPRIVATION INDEX (SDI)
********************************************************************************

/*
This section is optional. The main manuscript does not require SDI.
If reviewers or conference discussants ask for additional deprivation adjustment,
place an SDI file in $raw named either:
    sdi_county.dta
    sdi_county.csv

The file should contain fipscode and sdi. If it also contains year, the merge
will be by fipscode year; otherwise the SDI value is treated as time-invariant
across 2023-2025.
*/

global has_sdi 0

tempfile sdi_temp

capture confirm file "$sdi_dta"
if !_rc {
    di as text "Merging optional SDI file: $sdi_dta"
    preserve
        use "$sdi_dta", clear
        * Harmonize possible FIPS and SDI variable names if needed.
        capture confirm variable fipscode
        if _rc {
            foreach cand in FIPS fips county_fips countyfips geoid GEOID {
                capture confirm variable `cand'
                if !_rc {
                    rename `cand' fipscode
                    continue, break
                }
            }
        }
        capture confirm variable sdi
        if _rc {
            foreach cand in SDI sdi_score sdi_index social_deprivation_index Social_Deprivation_Index {
                capture confirm variable `cand'
                if !_rc {
                    rename `cand' sdi
                    continue, break
                }
            }
        }
        capture confirm string variable fipscode
        if !_rc {
            gen long fipscode_num = real(fipscode)
            drop fipscode
            rename fipscode_num fipscode
        }
        capture confirm numeric variable sdi
        if _rc destring sdi, replace force
        capture confirm variable year
        if !_rc local sdi_keys fipscode year
        else local sdi_keys fipscode
        keep `sdi_keys' sdi
        duplicates drop `sdi_keys', force
        save `sdi_temp', replace
    restore
    merge m:1 `sdi_keys' using `sdi_temp', keep(master match) nogen
}
else {
    capture confirm file "$sdi_csv"
    if !_rc {
        di as text "Merging optional SDI file: $sdi_csv"
        preserve
            import delimited "$sdi_csv", clear varnames(1)
            capture confirm variable fipscode
            if _rc {
                foreach cand in FIPS fips county_fips countyfips geoid GEOID {
                    capture confirm variable `cand'
                    if !_rc {
                        rename `cand' fipscode
                        continue, break
                    }
                }
            }
            capture confirm variable sdi
            if _rc {
                foreach cand in SDI sdi_score sdi_index social_deprivation_index Social_Deprivation_Index {
                    capture confirm variable `cand'
                    if !_rc {
                        rename `cand' sdi
                        continue, break
                    }
                }
            }
            capture confirm string variable fipscode
            if !_rc {
                gen long fipscode_num = real(fipscode)
                drop fipscode
                rename fipscode_num fipscode
            }
            capture confirm numeric variable sdi
            if _rc destring sdi, replace force
            capture confirm variable year
            if !_rc local sdi_keys fipscode year
            else local sdi_keys fipscode
            keep `sdi_keys' sdi
            duplicates drop `sdi_keys', force
            save `sdi_temp', replace
        restore
        merge m:1 `sdi_keys' using `sdi_temp', keep(master match) nogen
    }
    else {
        di as text "No optional SDI file found. SDI sensitivity models will be skipped."
    }
}

capture confirm variable sdi
if !_rc {
    capture confirm numeric variable sdi
    if _rc destring sdi, replace force
    label var sdi "Social Deprivation Index"
    global has_sdi 1
    summarize sdi
}
else {
    gen sdi = .
    label var sdi "Social Deprivation Index (not merged)"
    global has_sdi 0
}

* Convert proportion variables to percentage-point units for clean interpretation.
* Coefficients on *_pp variables = effect of a 1 percentage-point increase.
foreach v in pct_under18 pct_over65 pct_female pct_black pct_ai pct_hispanic pct_asian pct_white ///
             hs_completion some_college unemployment child_poverty pct_rural ///
             severe_housing pct_high_housing_cost pct_overcrowding pct_lack_necessities ///
             severe_housing_cost_burden long_commute homeownership ///
             uninsured uninsured_adults uninsured_children ///
             food_insecurity insufficient_sleep loneliness lack_social_support {
    capture drop `v'_pp
    gen `v'_pp = `v' * 100
}

* Social-pathway proxies are available only in the 2025 release in these files.
assert year == 2025 if !missing(loneliness_pp)
assert year == 2025 if !missing(lack_social_support_pp)

* Provider rate often appears small; keep original and create interpretable per-1,000 measure if desired.
capture drop mh_providers_1000
gen mh_providers_1000 = mh_providers * 1000

* Label key variables
label var mental_health "Poor mental health days"
label var suicide_rate "Age-adjusted suicide deaths per 100,000"
label var severe_housing_pp "Severe housing problems, pp"
label var pct_high_housing_cost_pp "Housing cost burden (>30% of income), pp"
label var severe_housing_cost_burden_pp "Severe housing cost burden (>50% of income), pp"
label var pct_overcrowding_pp "Overcrowding, pp"
label var pct_lack_necessities_pp "Lack of kitchen/plumbing facilities, pp"
label var long_commute_pp "Long commuting, pp"
label var homeownership_pp "Homeownership, pp"
label var food_insecurity_pp "Food insecurity, pp"
label var insufficient_sleep_pp "Insufficient sleep, pp"
label var loneliness_pp "Loneliness, pp"
label var lack_social_support_pp "Lack of social/emotional support, pp"
label var hs_completion_pp "High school completion, pp"

save "$analysis_file", replace

* Confirm that the suicide outcome is the age-adjusted CHR&R measure.
summarize suicide_rate
notes suicide_rate: Age-adjusted suicide mortality from v161_rawvalue. Crude suicide rate v161_other_data_1 is not used.


********************************************************************************
* 4. GLOBAL MODEL LISTS
********************************************************************************

global controls_pp ///
    pct_over65_pp pct_under18_pp pct_female_pp ///
    pct_black_pp pct_white_pp pct_hispanic_pp ///
    median_income unemployment_pp child_poverty_pp pct_rural_pp ///
    hs_completion_pp some_college_pp uninsured_pp mh_providers_1000

global controls_norural_pp ///
    pct_over65_pp pct_under18_pp pct_female_pp ///
    pct_black_pp pct_white_pp pct_hispanic_pp ///
    median_income unemployment_pp child_poverty_pp ///
    hs_completion_pp some_college_pp uninsured_pp mh_providers_1000

* Alternative control set for optional SDI models.
* This excludes income, unemployment, poverty, and education to avoid mechanically
* controlling for the same deprivation components twice.
global controls_basic_pp ///
    pct_over65_pp pct_under18_pp pct_female_pp ///
    pct_black_pp pct_white_pp pct_hispanic_pp ///
    pct_rural_pp uninsured_pp mh_providers_1000

global housing_pp ///
    severe_housing_cost_burden_pp pct_overcrowding_pp pct_lack_necessities_pp ///
    long_commute_pp homeownership_pp

* All housing indicators used anywhere in the primary separate-exposure models.
* Requiring all of them creates a common analytic sample across Table 2 rows.
global housing_all_pp ///
    severe_housing_pp pct_high_housing_cost_pp severe_housing_cost_burden_pp ///
    pct_overcrowding_pp pct_lack_necessities_pp long_commute_pp homeownership_pp

global demographic_covars_pp ///
    pct_over65_pp pct_under18_pp pct_female_pp ///
    pct_black_pp pct_white_pp pct_hispanic_pp

global socioeconomic_covars_pp ///
    median_income unemployment_pp child_poverty_pp pct_rural_pp ///
    hs_completion_pp some_college_pp

global healthcare_covars ///
    uninsured_pp mh_providers_1000


********************************************************************************
* 4A. OUTCOME-SPECIFIC ANALYTIC SAMPLE DERIVATION
********************************************************************************

/*
Primary models use common, outcome-specific complete-case samples. A record is
included only when the relevant outcome, all seven primary housing indicators,
and all adjustment covariates are observed. This prevents sample composition
from changing across rows of the primary tables and makes sample derivation
fully reproducible.
*/

capture drop nmiss_housing_all nmiss_demographic nmiss_socioeconomic nmiss_healthcare
capture drop sample_mh sample_suicide sample_food sample_sleep sample_loneliness sample_support
capture drop sample_mh_food sample_mh_sleep sample_mh_social sample_mh_allpath
capture drop sample_sui_food sample_sui_sleep sample_sui_social sample_sui_allpath

egen nmiss_housing_all = rowmiss($housing_all_pp)
egen nmiss_demographic = rowmiss($demographic_covars_pp)
egen nmiss_socioeconomic = rowmiss($socioeconomic_covars_pp)
egen nmiss_healthcare = rowmiss($healthcare_covars)

gen byte sample_mh = !missing(mental_health) & ///
    nmiss_housing_all == 0 & nmiss_demographic == 0 & ///
    nmiss_socioeconomic == 0 & nmiss_healthcare == 0

gen byte sample_suicide = !missing(suicide_rate) & ///
    nmiss_housing_all == 0 & nmiss_demographic == 0 & ///
    nmiss_socioeconomic == 0 & nmiss_healthcare == 0

label var sample_mh "Complete-case sample: poor mental health days"
label var sample_suicide "Complete-case sample: age-adjusted suicide mortality"

* Proxy-specific samples for supplementary housing -> pathway-proxy models.
gen byte sample_food = !missing(food_insecurity_pp) & ///
    nmiss_housing_all == 0 & nmiss_demographic == 0 & ///
    nmiss_socioeconomic == 0 & nmiss_healthcare == 0

gen byte sample_sleep = !missing(insufficient_sleep_pp) & ///
    nmiss_housing_all == 0 & nmiss_demographic == 0 & ///
    nmiss_socioeconomic == 0 & nmiss_healthcare == 0

gen byte sample_loneliness = !missing(loneliness_pp) & ///
    nmiss_housing_all == 0 & nmiss_demographic == 0 & ///
    nmiss_socioeconomic == 0 & nmiss_healthcare == 0

gen byte sample_support = !missing(lack_social_support_pp) & ///
    nmiss_housing_all == 0 & nmiss_demographic == 0 & ///
    nmiss_socioeconomic == 0 & nmiss_healthcare == 0

* Explicit samples for outcome models that add pathway proxies.
gen byte sample_mh_food = sample_mh & !missing(food_insecurity_pp)
gen byte sample_mh_sleep = sample_mh & !missing(insufficient_sleep_pp)
gen byte sample_mh_social = sample_mh & ///
    !missing(loneliness_pp, lack_social_support_pp)
gen byte sample_mh_allpath = sample_mh & ///
    !missing(food_insecurity_pp, insufficient_sleep_pp, loneliness_pp, lack_social_support_pp)

gen byte sample_sui_food = sample_suicide & !missing(food_insecurity_pp)
gen byte sample_sui_sleep = sample_suicide & !missing(insufficient_sleep_pp)
gen byte sample_sui_social = sample_suicide & ///
    !missing(loneliness_pp, lack_social_support_pp)
gen byte sample_sui_allpath = sample_suicide & ///
    !missing(food_insecurity_pp, insufficient_sleep_pp, loneliness_pp, lack_social_support_pp)

* ---------------- Sequential sample-derivation table ----------------
tempname samplepost
tempfile samplecounts
postfile `samplepost' byte step_order str90 step ///
    long poor_mental_health_n long suicide_mortality_n using `samplecounts', replace

quietly count
local mh_n1 = r(N)
local sui_n1 = r(N)
post `samplepost' (1) ("County-release records after geographic restrictions") (`mh_n1') (`sui_n1')

quietly count if !missing(mental_health)
local mh_n2 = r(N)
quietly count if !missing(suicide_rate)
local sui_n2 = r(N)
post `samplepost' (2) ("Outcome observed") (`mh_n2') (`sui_n2')

quietly count if !missing(mental_health) & nmiss_housing_all == 0
local mh_n3 = r(N)
quietly count if !missing(suicide_rate) & nmiss_housing_all == 0
local sui_n3 = r(N)
post `samplepost' (3) ("Outcome observed and all primary housing indicators complete") (`mh_n3') (`sui_n3')

quietly count if !missing(mental_health) & nmiss_housing_all == 0 & nmiss_demographic == 0
local mh_n4 = r(N)
quietly count if !missing(suicide_rate) & nmiss_housing_all == 0 & nmiss_demographic == 0
local sui_n4 = r(N)
post `samplepost' (4) ("Plus complete demographic covariates") (`mh_n4') (`sui_n4')

quietly count if !missing(mental_health) & nmiss_housing_all == 0 & ///
    nmiss_demographic == 0 & nmiss_socioeconomic == 0
local mh_n5 = r(N)
quietly count if !missing(suicide_rate) & nmiss_housing_all == 0 & ///
    nmiss_demographic == 0 & nmiss_socioeconomic == 0
local sui_n5 = r(N)
post `samplepost' (5) ("Plus complete socioeconomic covariates") (`mh_n5') (`sui_n5')

quietly count if sample_mh == 1
local mh_n6 = r(N)
quietly count if sample_suicide == 1
local sui_n6 = r(N)
post `samplepost' (6) ("Plus complete health care covariates: final analytic sample") (`mh_n6') (`sui_n6')

postclose `samplepost'

preserve
    use `samplecounts', clear
    sort step_order
    gen long mh_excluded_at_step = ///
        poor_mental_health_n[_n-1] - poor_mental_health_n if _n > 1
    gen long suicide_excluded_at_step = ///
        suicide_mortality_n[_n-1] - suicide_mortality_n if _n > 1
    gen double poor_mental_health_pct_initial = ///
        100 * poor_mental_health_n / poor_mental_health_n[1]
    gen double suicide_mortality_pct_initial = ///
        100 * suicide_mortality_n / suicide_mortality_n[1]
    format poor_mental_health_pct_initial suicide_mortality_pct_initial %9.1f
    save "$processed/analytic_sample_derivation.dta", replace
    export excel using "$output/TableS0B_Analytic_sample_derivation.xlsx", ///
        firstrow(variables) replace
    export delimited using "$output/TableS0B_Analytic_sample_derivation.csv", replace
restore

* ---------------- Variable-level missingness table ----------------
tempname misspost
tempfile misscounts
postfile `misspost' str40 variable_name str90 variable_label ///
    long total_n long nonmissing_n long missing_n double percent_missing ///
    using `misscounts', replace

local missingness_vars mental_health suicide_rate $housing_all_pp ///
    $demographic_covars_pp $socioeconomic_covars_pp $healthcare_covars

foreach v of local missingness_vars {
    quietly count
    local total_n = r(N)
    quietly count if !missing(`v')
    local nonmissing_n = r(N)
    local missing_n = `total_n' - `nonmissing_n'
    local percent_missing = 100 * `missing_n' / `total_n'
    local vlabel : variable label `v'
    if `"`vlabel'"' == "" local vlabel "`v'"
    post `misspost' ("`v'") (`"`vlabel'"') (`total_n') (`nonmissing_n') ///
        (`missing_n') (`percent_missing')
}
postclose `misspost'

preserve
    use `misscounts', clear
    format percent_missing %9.2f
    gsort -percent_missing
    save "$processed/primary_variable_missingness.dta", replace
    export excel using "$output/TableS0C_Primary_variable_missingness.xlsx", ///
        firstrow(variables) replace
    export delimited using "$output/TableS0C_Primary_variable_missingness.csv", replace
restore

* Display headline counts in the log.
di "================ ANALYTIC SAMPLE SUMMARY ================"
di as result "County-release records after geographic restrictions: " `mh_n1'
di as result "Poor mental health days observed: " `mh_n2'
di as result "Poor mental health days final analytic sample: " `mh_n6'
di as result "Suicide mortality observed: " `sui_n2'
di as result "Suicide mortality final analytic sample: " `sui_n6'
tab year sample_mh, missing
tab year sample_suicide, missing

* Save the corrected county-only analysis file with sample flags.
save "$analysis_file", replace


********************************************************************************
* 5. DESCRIPTIVE STATISTICS
********************************************************************************

di "================ DESCRIPTIVE STATISTICS ================"

tab year
tab region
tab housing_group
tab housing_cost_group
tab severe_cost_burden_group
tab overcrowding_group
tab lack_necessities_group
tab long_commute_group
tab homeownership_group

tabstat ///
    pct_under18_pp pct_over65_pp pct_female_pp ///
    pct_black_pp pct_ai_pp pct_hispanic_pp pct_asian_pp pct_white_pp ///
    hs_completion_pp some_college_pp ///
    median_income unemployment_pp child_poverty_pp pct_rural_pp ///
    long_commute_pp uninsured_pp mental_health mh_providers_1000 suicide_rate ///
    food_insecurity_pp insufficient_sleep_pp loneliness_pp lack_social_support_pp, ///
    stat(n mean sd min max) columns(statistics)

* Export variable-specific N, mean, SD, minimum, and maximum for Table 1 drafting.
tempname descpost
tempfile descdata
postfile `descpost' str45 variable_name str100 characteristic ///
    long observations double mean sd minimum maximum using `descdata', replace

local table1_vars ///
    pct_under18_pp pct_over65_pp pct_female_pp ///
    pct_ai_pp pct_asian_pp pct_black_pp pct_hispanic_pp pct_white_pp ///
    hs_completion_pp some_college_pp median_income unemployment_pp ///
    child_poverty_pp pct_rural_pp uninsured_pp mh_providers_1000 ///
    mental_health suicide_rate food_insecurity_pp insufficient_sleep_pp ///
    loneliness_pp lack_social_support_pp

foreach v of local table1_vars {
    quietly summarize `v'
    local this_n = r(N)
    local this_mean = r(mean)
    local this_sd = r(sd)
    local this_min = r(min)
    local this_max = r(max)
    local vlabel : variable label `v'
    if `"`vlabel'"' == "" local vlabel "`v'"
    post `descpost' ("`v'") (`"`vlabel'"') (`this_n') (`this_mean') ///
        (`this_sd') (`this_min') (`this_max')
}
postclose `descpost'

preserve
    use `descdata', clear
    format mean sd minimum maximum %12.3f
    export excel using "$output/Table1_Selected_county_release_characteristics.xlsx", ///
        firstrow(variables) replace
    export delimited using "$output/Table1_Selected_county_release_characteristics.csv", replace
restore

* Optional verbose descriptives and unadjusted t tests. These are not required
* for the manuscript and are disabled by default to keep the main log concise.
if $RUN_VERBOSE_DESCRIPTIVES == 1 {
    foreach g in housing_group housing_cost_group severe_cost_burden_group overcrowding_group ///
                 lack_necessities_group long_commute_group homeownership_group {
        di "--------------- Descriptives by `g' ---------------"
        tabstat ///
            pct_under18_pp pct_over65_pp pct_female_pp ///
            pct_black_pp pct_ai_pp pct_hispanic_pp pct_asian_pp pct_white_pp ///
            hs_completion_pp some_college_pp ///
            median_income unemployment_pp child_poverty_pp pct_rural_pp ///
            long_commute_pp uninsured_pp mental_health mh_providers_1000 suicide_rate ///
            food_insecurity_pp insufficient_sleep_pp loneliness_pp lack_social_support_pp, ///
            by(`g') stat(mean sd) columns(statistics)
    }

    foreach g in housing_group housing_cost_group severe_cost_burden_group overcrowding_group ///
                 lack_necessities_group long_commute_group homeownership_group {
        di "--------------- T-tests by `g' ---------------"
        ttest mental_health, by(`g')
        ttest suicide_rate, by(`g')
    }
}


********************************************************************************
* 6. MAIN PAPER ANALYSES: CONTINUOUS HOUSING EXPOSURES
********************************************************************************

di "================ MAIN MODELS: POOR MENTAL HEALTH DAYS ================"

eststo clear

reg mental_health severe_housing_pp $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
eststo mh_severehousing

reg mental_health pct_high_housing_cost_pp $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
eststo mh_highcost

reg mental_health severe_housing_cost_burden_pp $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
eststo mh_severecost

reg mental_health pct_overcrowding_pp $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
eststo mh_overcrowd

reg mental_health pct_lack_necessities_pp $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
eststo mh_lack

reg mental_health long_commute_pp $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
eststo mh_commute

reg mental_health homeownership_pp $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
eststo mh_homeown

esttab mh_severehousing mh_highcost mh_severecost mh_overcrowd mh_lack mh_commute mh_homeown ///
    using "$output/Table2_MH_main.rtf", replace se star(* 0.10 ** 0.05 *** 0.01) ///
    label b(3) se(3) stats(N r2, labels("Observations" "R-squared")) ///
    title("Table 2. Housing conditions and poor mental health days")


di "================ MAIN MODELS: AGE-ADJUSTED SUICIDE MORTALITY ================"

eststo clear

reg suicide_rate severe_housing_pp $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
eststo sui_severehousing

reg suicide_rate pct_high_housing_cost_pp $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
eststo sui_highcost

reg suicide_rate severe_housing_cost_burden_pp $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
eststo sui_severecost

reg suicide_rate pct_overcrowding_pp $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
eststo sui_overcrowd

reg suicide_rate pct_lack_necessities_pp $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
eststo sui_lack

reg suicide_rate long_commute_pp $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
eststo sui_commute

reg suicide_rate homeownership_pp $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
eststo sui_homeown

esttab sui_severehousing sui_highcost sui_severecost sui_overcrowd sui_lack sui_commute sui_homeown ///
    using "$output/Table3_Suicide_main.rtf", replace se star(* 0.10 ** 0.05 *** 0.01) ///
    label b(3) se(3) stats(N r2, labels("Observations" "R-squared")) ///
    title("Table 3. Housing conditions and age-adjusted suicide mortality")


********************************************************************************
* 7. ORIGINAL BINARY-CUTOFF SENSITIVITY MODELS
********************************************************************************

di "================ BINARY-CUTOFF SENSITIVITY MODELS ================"

eststo clear

* Use short stored-estimate names. eststo internally stores names with an _est_ prefix,
* so long variable-based names can exceed Stata's name length limit.
local bin_vars  housing_group housing_cost_group severe_cost_burden_group overcrowding_group lack_necessities_group long_commute_group homeownership_group
local bin_names hprob hcost scost crowd lack comm own
local nbin : word count `bin_vars'

forvalues i = 1/`nbin' {
    local x : word `i' of `bin_vars'
    local nm : word `i' of `bin_names'

    reg mental_health `x' $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
    eststo mhb_`nm'

    reg suicide_rate `x' $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
    eststo suib_`nm'
}

esttab mhb_* using "$output/TableS1_MH_binary_sensitivity.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)

esttab suib_* using "$output/TableS2_Suicide_binary_sensitivity.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)


********************************************************************************
* 8. COMBINED HOUSING MODELS
********************************************************************************

di "================ COMBINED HOUSING MODELS ================"

eststo clear

reg mental_health $housing_pp $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
eststo mh_combined
scalar freeze_b_mh_cost = _b[severe_housing_cost_burden_pp]
scalar freeze_b_mh_long = _b[long_commute_pp]
scalar freeze_b_mh_own  = _b[homeownership_pp]
scalar freeze_n_mh      = e(N)

reg suicide_rate $housing_pp $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
eststo sui_combined
scalar freeze_b_sui_crowd = _b[pct_overcrowding_pp]
scalar freeze_b_sui_lack  = _b[pct_lack_necessities_pp]
scalar freeze_n_sui       = e(N)

esttab mh_combined sui_combined ///
    using "$output/Table4_Combined_housing_models.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) ///
    stats(N r2, labels("Observations" "R-squared")) ///
    title("Table 4. Combined housing conditions and mental health outcomes")


********************************************************************************
* 9. RURAL INTERACTION MODELS
********************************************************************************

di "================ RURAL INTERACTION MODELS ================"

eststo clear

local house_vars severe_housing_pp pct_high_housing_cost_pp severe_housing_cost_burden_pp pct_overcrowding_pp pct_lack_necessities_pp long_commute_pp homeownership_pp
local house_nm   hprob hcost scost crowd lack comm own
local nhouse : word count `house_vars'

forvalues i = 1/`nhouse' {
    local x : word `i' of `house_vars'
    local nm : word `i' of `house_nm'

    reg mental_health c.`x'##c.pct_rural_pp $controls_norural_pp i.year if sample_mh == 1, vce(cluster fipscode)
    eststo mhr_`nm'

    reg suicide_rate c.`x'##c.pct_rural_pp $controls_norural_pp i.year if sample_suicide == 1, vce(cluster fipscode)
    eststo suir_`nm'
}

esttab mhr_* using "$output/TableS3_MH_rural_interactions.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)

esttab suir_* using "$output/TableS4_Suicide_rural_interactions.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)


********************************************************************************
* 10. REGION FIXED-EFFECT ROBUSTNESS
********************************************************************************

di "================ REGION FIXED EFFECT ROBUSTNESS ================"

eststo clear

* Reuse the short housing names defined above.
forvalues i = 1/`nhouse' {
    local x : word `i' of `house_vars'
    local nm : word `i' of `house_nm'

    reg mental_health `x' $controls_pp i.year i.region if sample_mh == 1, vce(cluster fipscode)
    eststo mhfe_`nm'

    reg suicide_rate `x' $controls_pp i.year i.region if sample_suicide == 1, vce(cluster fipscode)
    eststo suife_`nm'
}

esttab mhfe_* using "$output/TableS5_MH_region_FE.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)

esttab suife_* using "$output/TableS6_Suicide_region_FE.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)


********************************************************************************
* 10A. STATE FIXED-EFFECT ROBUSTNESS
********************************************************************************

/*
State fixed effects provide a stronger robustness check than Census region fixed
effects by accounting for time-invariant state-level policy, reporting, economic,
and institutional differences. These models are intended as supplementary checks,
not replacements for the main models.
*/

di "================ STATE FIXED EFFECT ROBUSTNESS ================"

eststo clear

forvalues i = 1/`nhouse' {
    local x : word `i' of `house_vars'
    local nm : word `i' of `house_nm'

    reg mental_health `x' $controls_pp i.year i.statecode if sample_mh == 1, vce(cluster fipscode)
    eststo mhst_`nm'

    reg suicide_rate `x' $controls_pp i.year i.statecode if sample_suicide == 1, vce(cluster fipscode)
    eststo suist_`nm'
}

esttab mhst_* using "$output/TableS11_MH_state_FE.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)

esttab suist_* using "$output/TableS12_Suicide_state_FE.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)

eststo clear
reg mental_health $housing_pp $controls_pp i.year i.statecode if sample_mh == 1, vce(cluster fipscode)
eststo mh_state_combined

reg suicide_rate $housing_pp $controls_pp i.year i.statecode if sample_suicide == 1, vce(cluster fipscode)
eststo sui_state_combined

esttab mh_state_combined sui_state_combined ///
    using "$output/TableS13_Combined_state_FE.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) ///
    stats(N r2, labels("Observations" "R-squared")) ///
    title("Supplementary Table. Combined housing models with state fixed effects")


********************************************************************************
* 10B. OPTIONAL SDI SENSITIVITY MODELS
********************************************************************************

/*
Run only if an external SDI variable was merged above. These models use SDI as
an alternative broad social deprivation adjustment, replacing the more detailed
socioeconomic controls to reduce over-adjustment. Interpret cautiously because
SDI may overlap conceptually with housing and socioeconomic disadvantage.
*/

if "$has_sdi" == "1" {

    di "================ SDI SENSITIVITY MODELS ================"

    capture drop nmiss_basic_sdi sample_mh_sdi sample_sui_sdi
    egen nmiss_basic_sdi = rowmiss($housing_all_pp $controls_basic_pp sdi)
    gen byte sample_mh_sdi = !missing(mental_health) & nmiss_basic_sdi == 0
    gen byte sample_sui_sdi = !missing(suicide_rate) & nmiss_basic_sdi == 0

    eststo clear

    forvalues i = 1/`nhouse' {
        local x : word `i' of `house_vars'
        local nm : word `i' of `house_nm'

        reg mental_health `x' $controls_basic_pp sdi i.year if sample_mh_sdi == 1, vce(cluster fipscode)
        eststo mhsdi_`nm'

        reg suicide_rate `x' $controls_basic_pp sdi i.year if sample_sui_sdi == 1, vce(cluster fipscode)
        eststo suisdi_`nm'
    }

    esttab mhsdi_* using "$output/TableS14_MH_SDI_sensitivity.rtf", replace ///
        se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)

    esttab suisdi_* using "$output/TableS15_Suicide_SDI_sensitivity.rtf", replace ///
        se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)

    eststo clear
    reg mental_health $housing_pp $controls_basic_pp sdi i.year if sample_mh_sdi == 1, vce(cluster fipscode)
    eststo mh_sdi_combined

    reg suicide_rate $housing_pp $controls_basic_pp sdi i.year if sample_sui_sdi == 1, vce(cluster fipscode)
    eststo sui_sdi_combined

    esttab mh_sdi_combined sui_sdi_combined ///
        using "$output/TableS16_Combined_SDI_sensitivity.rtf", replace ///
        se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) ///
        stats(N r2, labels("Observations" "R-squared")) ///
        title("Supplementary Table. Combined housing models with SDI adjustment")
}
else {
    di as text "SDI sensitivity models skipped because no SDI variable was available."
}


********************************************************************************
* 11. PATHWAY-PROXY ANALYSES TO STRENGTHEN PAPER
********************************************************************************

/*
Interpretation:
These models do NOT establish causal mediation.
They test whether housing exposures are associated with county-level proxies
for plausible pathways discussed in the manuscript:
  - material hardship: food insecurity
  - time scarcity / physiological stress: insufficient sleep
  - social isolation/support: loneliness, lack social/emotional support, social associations

Recommended manuscript wording:
"To examine whether the observed associations were consistent with theorized pathways,
we conducted supplementary pathway-proxy analyses using county-level measures of
food insecurity, insufficient sleep, loneliness, and lack of social and emotional support."
*/

di "================ PATHWAY-PROXY MODELS: HOUSING -> PATHWAY PROXIES ================"

eststo clear

* Material hardship pathway
reg food_insecurity_pp severe_housing_cost_burden_pp $controls_pp i.year if sample_food == 1, vce(cluster fipscode)
eststo path_food_cost

reg food_insecurity_pp pct_high_housing_cost_pp $controls_pp i.year if sample_food == 1, vce(cluster fipscode)
eststo path_food_highcost

* Time scarcity / sleep pathway
reg insufficient_sleep_pp long_commute_pp $controls_pp i.year if sample_sleep == 1, vce(cluster fipscode)
eststo path_sleep_commute

reg insufficient_sleep_pp pct_overcrowding_pp $controls_pp i.year if sample_sleep == 1, vce(cluster fipscode)
eststo path_sleep_overcrowd

reg insufficient_sleep_pp pct_lack_necessities_pp $controls_pp i.year if sample_sleep == 1, vce(cluster fipscode)
eststo path_sleep_lack

* Social isolation / support pathway
reg loneliness_pp pct_overcrowding_pp $controls_pp i.year if sample_loneliness == 1, vce(cluster fipscode)
eststo path_lonely_overcrowd

reg loneliness_pp pct_lack_necessities_pp $controls_pp i.year if sample_loneliness == 1, vce(cluster fipscode)
eststo path_lonely_lack

reg lack_social_support_pp pct_overcrowding_pp $controls_pp i.year if sample_support == 1, vce(cluster fipscode)
eststo path_support_overcrowd

reg lack_social_support_pp pct_lack_necessities_pp $controls_pp i.year if sample_support == 1, vce(cluster fipscode)
eststo path_support_lack

esttab path_* using "$output/TableS7_Pathway_proxy_models.rtf", replace ///
    se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) ///
    stats(N r2, labels("Observations" "R-squared")) ///
    title("Supplementary Table. Housing conditions and pathway-proxy measures")


********************************************************************************
* NOTE: OBSOLETE NON-COMMON-SAMPLE PATHWAY-ADJUSTMENT TABLES REMOVED
********************************************************************************

/*
The prior TableS8/TableS9 models compared a full-sample base model with smaller
proxy-specific adjusted models. Those tables are intentionally not reproduced.
Phase II generates only same-sample base-versus-adjusted pathway comparisons.
*/

********************************************************************************
* 12. OPTIONAL EXPLORATORY CHILD-COMPOSITION INTERACTIONS
********************************************************************************

if $RUN_CHILD_INTERACTIONS == 1 {
    di "================ CHILD-COMPOSITION INTERACTION MODELS ================"

    eststo clear

    reg suicide_rate c.pct_lack_necessities_pp##c.pct_under18_pp ///
        pct_over65_pp pct_female_pp pct_black_pp pct_white_pp pct_hispanic_pp ///
        median_income unemployment_pp child_poverty_pp pct_rural_pp ///
        hs_completion_pp some_college_pp uninsured_pp mh_providers_1000 i.year ///
        if sample_suicide == 1, vce(cluster fipscode)
    eststo sui_lack_child

    reg suicide_rate c.pct_overcrowding_pp##c.pct_under18_pp ///
        pct_over65_pp pct_female_pp pct_black_pp pct_white_pp pct_hispanic_pp ///
        median_income unemployment_pp child_poverty_pp pct_rural_pp ///
        hs_completion_pp some_college_pp uninsured_pp mh_providers_1000 i.year ///
        if sample_suicide == 1, vce(cluster fipscode)
    eststo sui_overcrowd_child

    esttab sui_lack_child sui_overcrowd_child ///
        using "$output/Exploratory_Suicide_child_composition_interactions.rtf", replace ///
        se star(* 0.10 ** 0.05 *** 0.01) label b(3) se(3) stats(N r2)


}
else {
    di as text "Exploratory child-composition interactions skipped by configuration."
}

********************************************************************************
* 13. COEFFICIENT PLOTS
********************************************************************************

if $RUN_FIGURES == 1 {
    /*
    Important:
    Several earlier sections use eststo clear to keep table output clean. That means
    we should re-estimate the plotting models here instead of trying to restore
    previously stored estimates. This avoids r(111) "estimation result not found".
    */

    capture which coefplot
    if _rc {
        di as text "coefplot is not installed. Attempting installation from SSC..."
        capture ssc install coefplot, replace
    }

    capture which coefplot
    if !_rc {

        * Main combined coefficient plot: poor mental health
        quietly reg mental_health $housing_pp $controls_pp i.year if sample_mh == 1, vce(cluster fipscode)
        estimates store fig_mh_combined

        coefplot fig_mh_combined, ///
            keep(severe_housing_cost_burden_pp pct_overcrowding_pp pct_lack_necessities_pp long_commute_pp homeownership_pp) ///
            coeflabels( ///
                severe_housing_cost_burden_pp = "Severe housing cost burden" ///
                pct_overcrowding_pp = "Overcrowding" ///
                pct_lack_necessities_pp = "Lack of kitchen/plumbing facilities" ///
                long_commute_pp = "Long commuting" ///
                homeownership_pp = "Homeownership") ///
            xline(0, lpattern(dash)) ///
            xtitle("Change in poor mental health days per 1 percentage-point increase") ///
            title("A. Poor Mental Health Days") ///
            name(Figure1A, replace)
        graph export "$output/Figure1A_coefplot_distress.png", replace width(2000)

        * Main combined coefficient plot: suicide
        quietly reg suicide_rate $housing_pp $controls_pp i.year if sample_suicide == 1, vce(cluster fipscode)
        estimates store fig_sui_combined

        coefplot fig_sui_combined, ///
            keep(severe_housing_cost_burden_pp pct_overcrowding_pp pct_lack_necessities_pp long_commute_pp homeownership_pp) ///
            coeflabels( ///
                severe_housing_cost_burden_pp = "Severe housing cost burden" ///
                pct_overcrowding_pp = "Overcrowding" ///
                pct_lack_necessities_pp = "Lack of kitchen/plumbing facilities" ///
                long_commute_pp = "Long commuting" ///
                homeownership_pp = "Homeownership") ///
            xline(0, lpattern(dash)) ///
            xtitle("Change in age-adjusted suicide deaths per 100,000 per 1 percentage-point increase") ///
            title("B. Age-Adjusted Suicide Mortality") ///
            name(Figure1B, replace)
        graph export "$output/Figure1B_coefplot_suicide.png", replace width(2000)

        graph combine Figure1A Figure1B, cols(1) xsize(10) ysize(12) ///
            title("Mutually Adjusted Associations Between Housing Conditions and Mental Health Outcomes")
        graph export "$output/Figure1_Combined_housing_outcomes.png", replace width(2200)

        * Pathway-proxy figure: housing -> selected proxies
        quietly reg food_insecurity_pp severe_housing_cost_burden_pp $controls_pp i.year if sample_food == 1, vce(cluster fipscode)
        estimates store fig_food_cost

        quietly reg insufficient_sleep_pp long_commute_pp $controls_pp i.year if sample_sleep == 1, vce(cluster fipscode)
        estimates store fig_sleep_commute

        quietly reg loneliness_pp pct_overcrowding_pp $controls_pp i.year if sample_loneliness == 1, vce(cluster fipscode)
        estimates store fig_lonely_overcrowd

        quietly reg lack_social_support_pp pct_lack_necessities_pp $controls_pp i.year if sample_support == 1, vce(cluster fipscode)
        estimates store fig_support_lack

        coefplot ///
            (fig_food_cost, keep(severe_housing_cost_burden_pp) label("Food insecurity")) ///
            (fig_sleep_commute, keep(long_commute_pp) label("Insufficient sleep")) ///
            (fig_lonely_overcrowd, keep(pct_overcrowding_pp) label("Loneliness")) ///
            (fig_support_lack, keep(pct_lack_necessities_pp) label("Lack social support")), ///
            coeflabels( ///
                severe_housing_cost_burden_pp = "Severe housing cost burden" ///
                long_commute_pp = "Long commuting" ///
                pct_overcrowding_pp = "Overcrowding" ///
                pct_lack_necessities_pp = "Lack kitchen/plumbing facilities") ///
            xline(0, lpattern(dash)) ///
            xtitle("Adjusted percentage-point difference in pathway-proxy outcome per 1-percentage-point higher housing exposure") ///
            title("Supplementary Pathway-Proxy Analyses") ///
            note("Associational county-level models; not causal mediation.", size(small))
        graph export "$output/FigureS1_pathway_proxy_coefficients.png", replace width(2200)

    }
    else {
        di as error "coefplot is unavailable. Coefficient plots were skipped."
    }


}
else {
    di as text "Coefficient figures skipped by configuration."
}

********************************************************************************
* 14. PHASE I FINAL DATA AND MODEL CHECKS
********************************************************************************

di "================ FINAL ANALYTIC SAMPLE CHECKS ================"
misstable summarize mental_health suicide_rate $housing_all_pp $controls_pp ///
    food_insecurity_pp insufficient_sleep_pp loneliness_pp lack_social_support_pp

count if sample_mh == 1
local final_mh_n = r(N)
count if sample_suicide == 1
local final_sui_n = r(N)

di as result "Verified poor mental health analytic sample: " `final_mh_n'
di as result "Verified suicide mortality analytic sample: " `final_sui_n'

tab year if sample_mh == 1
tab year if sample_suicide == 1

* Verify that every common-sample record is complete on all required variables.
assert !missing(mental_health) & nmiss_housing_all == 0 & ///
    nmiss_demographic == 0 & nmiss_socioeconomic == 0 & nmiss_healthcare == 0 ///
    if sample_mh == 1
assert !missing(suicide_rate) & nmiss_housing_all == 0 & ///
    nmiss_demographic == 0 & nmiss_socioeconomic == 0 & nmiss_healthcare == 0 ///
    if sample_suicide == 1

* Freeze-candidate sample and model checks.
quietly count
local check_total = r(N)
assert `check_total' == $EXPECTED_TOTAL
quietly count if !missing(mental_health)
local check_mh_observed = r(N)
assert `check_mh_observed' == $EXPECTED_MH_OBSERVED
quietly count if !missing(suicide_rate)
local check_sui_observed = r(N)
assert `check_sui_observed' == $EXPECTED_SUI_OBSERVED
quietly count if sample_mh == 1
local check_mh_final = r(N)
assert `check_mh_final' == $EXPECTED_MH_FINAL
quietly count if sample_suicide == 1
local check_sui_final = r(N)
assert `check_sui_final' == $EXPECTED_SUI_FINAL
assert scalar(freeze_n_mh) == $EXPECTED_MH_FINAL
assert scalar(freeze_n_sui) == $EXPECTED_SUI_FINAL

if $STRICT_FREEZE_CHECKS == 1 {
    assert inrange(scalar(freeze_b_mh_long), 0.005, 0.009)
    assert inrange(scalar(freeze_b_mh_cost), 0.004, 0.011)
    assert inrange(scalar(freeze_b_sui_crowd), 0.10, 0.60)
    assert inrange(scalar(freeze_b_sui_lack), 0.00, 0.80)
}

save "$analysis_file", replace

* Confirm that the suicide outcome is the age-adjusted CHR&R measure.
summarize suicide_rate
notes suicide_rate: Age-adjusted suicide mortality from v161_rawvalue. Crude suicide rate v161_other_data_1 is not used.

********************************************************************************
* PHASE I COMPLETE — START PHASE II REVIEWER-DRIVEN QA
********************************************************************************

log close
clear
log using "$output/02_reviewer_QA.log", text replace

di "Phase I completed successfully. Starting reviewer-driven QA."
di "Analysis file: $analysis_file"

********************************************************************************
* II-1. LOAD AND VERIFY THE FREEZE-CANDIDATE ANALYSIS FILE
********************************************************************************

use "$analysis_file", clear

local required_vars ///
    state county year statecode countycode fipscode region ///
    mental_health suicide_rate ///
    severe_housing_pp pct_high_housing_cost_pp ///
    severe_housing_cost_burden_pp pct_overcrowding_pp ///
    pct_lack_necessities_pp long_commute_pp homeownership_pp ///
    pct_over65_pp pct_under18_pp pct_female_pp ///
    pct_black_pp pct_white_pp pct_hispanic_pp ///
    median_income unemployment_pp child_poverty_pp pct_rural_pp ///
    hs_completion_pp some_college_pp uninsured_pp mh_providers_1000 ///
    food_insecurity_pp insufficient_sleep_pp loneliness_pp ///
    lack_social_support_pp

foreach v of local required_vars {
    capture confirm variable `v'
    if _rc {
        di as error "Required variable `v' is absent from the analysis-ready file."
        error 111
    }
}

* Confirm county-only records and one record per county/release year.
assert countycode > 0 & !missing(countycode)
assert !inlist(statecode, 60, 66, 69, 72, 78) & !missing(statecode)
isid fipscode year

********************************************************************************
* II-2. ANALYTIC VARIABLE BLOCKS AND QA SAMPLE FLAGS
********************************************************************************

global housing_pp ///
    severe_housing_cost_burden_pp pct_overcrowding_pp ///
    pct_lack_necessities_pp long_commute_pp homeownership_pp

global housing_all_pp ///
    severe_housing_pp pct_high_housing_cost_pp ///
    severe_housing_cost_burden_pp pct_overcrowding_pp ///
    pct_lack_necessities_pp long_commute_pp homeownership_pp

global demographic_covars_pp ///
    pct_over65_pp pct_under18_pp pct_female_pp ///
    pct_black_pp pct_white_pp pct_hispanic_pp

global socioeconomic_core_pp ///
    median_income unemployment_pp child_poverty_pp ///
    hs_completion_pp some_college_pp

global healthcare_covars ///
    uninsured_pp mh_providers_1000

global controls_pp ///
    $demographic_covars_pp median_income unemployment_pp child_poverty_pp ///
    pct_rural_pp hs_completion_pp some_college_pp ///
    $healthcare_covars

* Sequential adjustment blocks. Release-year fixed effects are added separately.
global adjust_m1 ///
    $demographic_covars_pp pct_rural_pp

global adjust_m2 ///
    $adjust_m1 $socioeconomic_core_pp

global adjust_m3 ///
    $adjust_m2 $healthcare_covars

* Reconstruct QA-specific common samples to verify the saved sample flags.
capture drop qa_nmiss_housing qa_nmiss_demo qa_nmiss_ses qa_nmiss_hc
capture drop qa_sample_mh qa_sample_sui

egen qa_nmiss_housing = rowmiss($housing_all_pp)
egen qa_nmiss_demo    = rowmiss($demographic_covars_pp)
egen qa_nmiss_ses     = rowmiss($socioeconomic_core_pp pct_rural_pp)
egen qa_nmiss_hc      = rowmiss($healthcare_covars)

gen byte qa_sample_mh = !missing(mental_health) & ///
    qa_nmiss_housing == 0 & qa_nmiss_demo == 0 & ///
    qa_nmiss_ses == 0 & qa_nmiss_hc == 0

gen byte qa_sample_sui = !missing(suicide_rate) & ///
    qa_nmiss_housing == 0 & qa_nmiss_demo == 0 & ///
    qa_nmiss_ses == 0 & qa_nmiss_hc == 0

label var qa_sample_mh  "QA complete-case sample: poor mental health days"
label var qa_sample_sui "QA complete-case sample: suicide mortality"

* Confirm consistency with sample flags saved by the corrected full analysis.
capture confirm variable sample_mh
if !_rc assert qa_sample_mh == sample_mh

capture confirm variable sample_suicide
if !_rc assert qa_sample_sui == sample_suicide

quietly count
local n_countyyear = r(N)
quietly count if qa_sample_mh == 1
local n_mh = r(N)
quietly count if qa_sample_sui == 1
local n_sui = r(N)
quietly count if !missing(suicide_rate)
local n_sui_observed = r(N)

di "================ QA SAMPLE VERIFICATION ================"
di as result "Eligible county-release records: `n_countyyear'"
di as result "Poor mental health final sample: `n_mh'"
di as result "Suicide outcome observed: `n_sui_observed'"
di as result "Suicide final sample: `n_sui'"

********************************************************************************
* II-3. HELPER PROGRAM: POST COEFFICIENTS FROM THE MOST RECENT MODEL
********************************************************************************

capture program drop qa_post_estimates
program define qa_post_estimates
    version 18
    syntax, HANDLE(name) OUTCOME(string asis) ANALYSIS(string asis) ///
        ADJUSTMENT(string asis) VARS(varlist)

    local model_n = e(N)
    local model_r2 = e(r2)
    local model_df = e(df_r)

    foreach v of local vars {
        capture local b = _b[`v']
        if !_rc {
            local se = _se[`v']
            local tstat = `b' / `se'
            local pval = 2 * ttail(`model_df', abs(`tstat'))
            local crit = invttail(`model_df', 0.025)
            local lo = `b' - `crit' * `se'
            local hi = `b' + `crit' * `se'
            local vlabel : variable label `v'
            if `"`vlabel'"' == "" local vlabel "`v'"

            post `handle' (`"`outcome'"') (`"`analysis'"') ///
                (`"`adjustment'"') ("`v'") (`"`vlabel'"') ///
                (`b') (`se') (`lo') (`hi') (`pval') ///
                (`model_n') (`model_r2')
        }
    }
end

********************************************************************************
* II-4. SUICIDE OUTCOME AVAILABILITY AND SAMPLE-SELECTION COMPARISONS
********************************************************************************

/*
Table S0D compares county-release observations with and without a reportable
age-adjusted suicide mortality estimate. The data alone identify differential
availability; the manuscript should separately cite CHR&R documentation for the
small-number suppression/reliability rule.
*/

di "================ SUICIDE OUTCOME AVAILABILITY COMPARISON ================"
capture drop qa_sui_available qa_year_* qa_region_*
gen byte qa_sui_available = !missing(suicide_rate)
label define qa_avail_lbl 0 "Suicide estimate unavailable" 1 "Suicide estimate available", replace
label values qa_sui_available qa_avail_lbl

* Categorical indicators for release year and Census region.
foreach y in 2023 2024 2025 {
    gen byte qa_year_`y' = year == `y'
    label var qa_year_`y' "Release year `y', %"
}

gen byte qa_region_ne = region == 1
label var qa_region_ne "Northeast, %"
gen byte qa_region_mw = region == 2
label var qa_region_mw "Midwest, %"
gen byte qa_region_so = region == 3
label var qa_region_so "South, %"
gen byte qa_region_we = region == 4
label var qa_region_we "West, %"

local availability_cont ///
    pct_rural_pp median_income unemployment_pp child_poverty_pp ///
    uninsured_pp mh_providers_1000 ///
    severe_housing_cost_burden_pp pct_overcrowding_pp ///
    pct_lack_necessities_pp long_commute_pp homeownership_pp ///
    pct_under18_pp pct_over65_pp pct_female_pp ///
    pct_black_pp pct_white_pp pct_hispanic_pp ///
    hs_completion_pp some_college_pp mental_health

local availability_cat ///
    qa_year_2023 qa_year_2024 qa_year_2025 ///
    qa_region_ne qa_region_mw qa_region_so qa_region_we

tempname availpost
tempfile availdata
postfile `availpost' str80 characteristic str20 characteristic_type ///
    long available_n double available_mean available_sd ///
    long unavailable_n double unavailable_mean unavailable_sd ///
    double standardized_difference abs_standardized_difference ///
    using `availdata', replace

foreach v of local availability_cont {
    quietly summarize `v' if qa_sui_available == 1
    local n1 = r(N)
    local m1 = r(mean)
    local s1 = r(sd)

    quietly summarize `v' if qa_sui_available == 0
    local n0 = r(N)
    local m0 = r(mean)
    local s0 = r(sd)

    local smd = .
    if (`n1' > 1 & `n0' > 1) {
        local pooled_sd = sqrt((`s1'^2 + `s0'^2) / 2)
        if (`pooled_sd' > 0) local smd = (`m1' - `m0') / `pooled_sd'
    }
    local abs_smd = abs(`smd')
    local vlabel : variable label `v'
    if `"`vlabel'"' == "" local vlabel "`v'"

    post `availpost' (`"`vlabel'"') ("Continuous") ///
        (`n1') (`m1') (`s1') (`n0') (`m0') (`s0') ///
        (`smd') (`abs_smd')
}

foreach v of local availability_cat {
    quietly summarize `v' if qa_sui_available == 1
    local n1 = r(N)
    local p1 = r(mean)

    quietly summarize `v' if qa_sui_available == 0
    local n0 = r(N)
    local p0 = r(mean)

    local smd = .
    local pooled_pvar = ((`p1' * (1 - `p1')) + (`p0' * (1 - `p0'))) / 2
    if (`pooled_pvar' > 0) local smd = (`p1' - `p0') / sqrt(`pooled_pvar')
    local abs_smd = abs(`smd')
    local vlabel : variable label `v'

    post `availpost' (`"`vlabel'"') ("Categorical, %") ///
        (`n1') (100 * `p1') (.) (`n0') (100 * `p0') (.) ///
        (`smd') (`abs_smd')
}
postclose `availpost'

preserve
    use `availdata', clear
    gsort -abs_standardized_difference characteristic
    format available_mean unavailable_mean available_sd unavailable_sd %12.3f
    format standardized_difference abs_standardized_difference %9.3f
    save "$processed/suicide_availability_comparison.dta", replace
    export excel using "$output/TableS0D_Suicide_availability_comparison.xlsx", ///
        firstrow(variables) replace
    export delimited using "$output/TableS0D_Suicide_availability_comparison.csv", replace
restore

* Additional comparison: among county-releases with a suicide estimate, compare
* final complete cases with the small number excluded for exposure/covariate missingness.
di "================ SUICIDE COMPLETE-CASE COMPARISON ================"
capture drop qa_sui_final
gen byte qa_sui_final = qa_sample_sui if qa_sui_available == 1
label define qa_final_lbl 0 "Outcome observed but excluded" 1 "Final analytic sample", replace
label values qa_sui_final qa_final_lbl

tempname ccpost
tempfile ccdata
postfile `ccpost' str80 characteristic str20 characteristic_type ///
    long included_n double included_mean included_sd ///
    long excluded_n double excluded_mean excluded_sd ///
    double standardized_difference abs_standardized_difference ///
    using `ccdata', replace

foreach v of local availability_cont {
    quietly summarize `v' if qa_sui_available == 1 & qa_sui_final == 1
    local n1 = r(N)
    local m1 = r(mean)
    local s1 = r(sd)

    quietly summarize `v' if qa_sui_available == 1 & qa_sui_final == 0
    local n0 = r(N)
    local m0 = r(mean)
    local s0 = r(sd)

    local smd = .
    if (`n1' > 1 & `n0' > 1) {
        local pooled_sd = sqrt((`s1'^2 + `s0'^2) / 2)
        if (`pooled_sd' > 0) local smd = (`m1' - `m0') / `pooled_sd'
    }
    local abs_smd = abs(`smd')
    local vlabel : variable label `v'
    if `"`vlabel'"' == "" local vlabel "`v'"

    post `ccpost' (`"`vlabel'"') ("Continuous") ///
        (`n1') (`m1') (`s1') (`n0') (`m0') (`s0') ///
        (`smd') (`abs_smd')
}

foreach v of local availability_cat {
    quietly summarize `v' if qa_sui_available == 1 & qa_sui_final == 1
    local n1 = r(N)
    local p1 = r(mean)

    quietly summarize `v' if qa_sui_available == 1 & qa_sui_final == 0
    local n0 = r(N)
    local p0 = r(mean)

    local smd = .
    local pooled_pvar = ((`p1' * (1 - `p1')) + (`p0' * (1 - `p0'))) / 2
    if (`pooled_pvar' > 0) local smd = (`p1' - `p0') / sqrt(`pooled_pvar')
    local abs_smd = abs(`smd')
    local vlabel : variable label `v'

    post `ccpost' (`"`vlabel'"') ("Categorical, %") ///
        (`n1') (100 * `p1') (.) (`n0') (100 * `p0') (.) ///
        (`smd') (`abs_smd')
}
postclose `ccpost'

preserve
    use `ccdata', clear
    gsort -abs_standardized_difference characteristic
    format included_mean excluded_mean included_sd excluded_sd %12.3f
    format standardized_difference abs_standardized_difference %9.3f
    save "$processed/suicide_complete_case_comparison.dta", replace
    export excel using "$output/TableS0E_Suicide_complete_case_comparison.xlsx", ///
        firstrow(variables) replace
    export delimited using "$output/TableS0E_Suicide_complete_case_comparison.csv", replace
restore

********************************************************************************
* II-5. SEQUENTIAL COVARIATE-ADJUSTMENT MODELS
********************************************************************************

/*
All nested models for a given outcome use the same final complete-case sample.
This isolates changes due to covariate blocks rather than changes in observations.

Model 1: release year + demographic composition + rural population share
Model 2: Model 1 + socioeconomic context
Model 3: Model 2 + uninsured rate + mental health provider density
*/

di "================ SEQUENTIAL COVARIATE ADJUSTMENT ================"
tempname seqpost
tempfile seqdata
postfile `seqpost' str35 outcome str55 analysis_name str40 adjustment_level ///
    str40 variable_name str80 variable_label ///
    double beta standard_error ci_lower ci_upper p_value ///
    long observations double r_squared using `seqdata', replace

eststo clear

* Key association 1: long commuting -> poor mental health days.
reg mental_health long_commute_pp $adjust_m1 i.year if qa_sample_mh == 1, vce(cluster fipscode)
eststo qseq_mh_long_m1
qa_post_estimates, handle(`seqpost') outcome("Poor mental health days") ///
    analysis("Long commuting") adjustment("Model 1: demographic/geographic") ///
    vars(long_commute_pp)

reg mental_health long_commute_pp $adjust_m2 i.year if qa_sample_mh == 1, vce(cluster fipscode)
eststo qseq_mh_long_m2
qa_post_estimates, handle(`seqpost') outcome("Poor mental health days") ///
    analysis("Long commuting") adjustment("Model 2: plus socioeconomic") ///
    vars(long_commute_pp)

reg mental_health long_commute_pp $adjust_m3 i.year if qa_sample_mh == 1, vce(cluster fipscode)
eststo qseq_mh_long_m3
qa_post_estimates, handle(`seqpost') outcome("Poor mental health days") ///
    analysis("Long commuting") adjustment("Model 3: plus health care") ///
    vars(long_commute_pp)

* Key association 2: overcrowding -> suicide mortality.
reg suicide_rate pct_overcrowding_pp $adjust_m1 i.year if qa_sample_sui == 1, vce(cluster fipscode)
eststo qseq_sui_crowd_m1
qa_post_estimates, handle(`seqpost') outcome("Suicide mortality") ///
    analysis("Overcrowding") adjustment("Model 1: demographic/geographic") ///
    vars(pct_overcrowding_pp)

reg suicide_rate pct_overcrowding_pp $adjust_m2 i.year if qa_sample_sui == 1, vce(cluster fipscode)
eststo qseq_sui_crowd_m2
qa_post_estimates, handle(`seqpost') outcome("Suicide mortality") ///
    analysis("Overcrowding") adjustment("Model 2: plus socioeconomic") ///
    vars(pct_overcrowding_pp)

reg suicide_rate pct_overcrowding_pp $adjust_m3 i.year if qa_sample_sui == 1, vce(cluster fipscode)
eststo qseq_sui_crowd_m3
qa_post_estimates, handle(`seqpost') outcome("Suicide mortality") ///
    analysis("Overcrowding") adjustment("Model 3: plus health care") ///
    vars(pct_overcrowding_pp)

* Key association 3: lack of kitchen/plumbing facilities -> suicide mortality.
reg suicide_rate pct_lack_necessities_pp $adjust_m1 i.year if qa_sample_sui == 1, vce(cluster fipscode)
eststo qseq_sui_lack_m1
qa_post_estimates, handle(`seqpost') outcome("Suicide mortality") ///
    analysis("Lack kitchen/plumbing facilities") ///
    adjustment("Model 1: demographic/geographic") vars(pct_lack_necessities_pp)

reg suicide_rate pct_lack_necessities_pp $adjust_m2 i.year if qa_sample_sui == 1, vce(cluster fipscode)
eststo qseq_sui_lack_m2
qa_post_estimates, handle(`seqpost') outcome("Suicide mortality") ///
    analysis("Lack kitchen/plumbing facilities") ///
    adjustment("Model 2: plus socioeconomic") vars(pct_lack_necessities_pp)

reg suicide_rate pct_lack_necessities_pp $adjust_m3 i.year if qa_sample_sui == 1, vce(cluster fipscode)
eststo qseq_sui_lack_m3
qa_post_estimates, handle(`seqpost') outcome("Suicide mortality") ///
    analysis("Lack kitchen/plumbing facilities") ///
    adjustment("Model 3: plus health care") vars(pct_lack_necessities_pp)

esttab ///
    qseq_mh_long_m1 qseq_mh_long_m2 qseq_mh_long_m3 ///
    qseq_sui_crowd_m1 qseq_sui_crowd_m2 qseq_sui_crowd_m3 ///
    qseq_sui_lack_m1 qseq_sui_lack_m2 qseq_sui_lack_m3 ///
    using "$output/TableS0F1_Sequential_key_exposures.rtf", replace ///
    keep(long_commute_pp pct_overcrowding_pp pct_lack_necessities_pp) ///
    mtitles("Commute M1" "Commute M2" "Commute M3" ///
            "Crowding M1" "Crowding M2" "Crowding M3" ///
            "Facilities M1" "Facilities M2" "Facilities M3") ///
    b(3) ci(3) label star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared")) ///
    title("Sequential adjustment for key housing-outcome associations")

* Mutually adjusted housing model: poor mental health days.
reg mental_health $housing_pp $adjust_m1 i.year if qa_sample_mh == 1, vce(cluster fipscode)
eststo qseq_mh_all_m1
qa_post_estimates, handle(`seqpost') outcome("Poor mental health days") ///
    analysis("Mutually adjusted housing model") ///
    adjustment("Model 1: demographic/geographic") vars($housing_pp)

reg mental_health $housing_pp $adjust_m2 i.year if qa_sample_mh == 1, vce(cluster fipscode)
eststo qseq_mh_all_m2
qa_post_estimates, handle(`seqpost') outcome("Poor mental health days") ///
    analysis("Mutually adjusted housing model") ///
    adjustment("Model 2: plus socioeconomic") vars($housing_pp)

reg mental_health $housing_pp $adjust_m3 i.year if qa_sample_mh == 1, vce(cluster fipscode)
eststo qseq_mh_all_m3
qa_post_estimates, handle(`seqpost') outcome("Poor mental health days") ///
    analysis("Mutually adjusted housing model") ///
    adjustment("Model 3: plus health care") vars($housing_pp)

* Mutually adjusted housing model: suicide mortality.
reg suicide_rate $housing_pp $adjust_m1 i.year if qa_sample_sui == 1, vce(cluster fipscode)
eststo qseq_sui_all_m1
qa_post_estimates, handle(`seqpost') outcome("Suicide mortality") ///
    analysis("Mutually adjusted housing model") ///
    adjustment("Model 1: demographic/geographic") vars($housing_pp)

reg suicide_rate $housing_pp $adjust_m2 i.year if qa_sample_sui == 1, vce(cluster fipscode)
eststo qseq_sui_all_m2
qa_post_estimates, handle(`seqpost') outcome("Suicide mortality") ///
    analysis("Mutually adjusted housing model") ///
    adjustment("Model 2: plus socioeconomic") vars($housing_pp)

reg suicide_rate $housing_pp $adjust_m3 i.year if qa_sample_sui == 1, vce(cluster fipscode)
eststo qseq_sui_all_m3
qa_post_estimates, handle(`seqpost') outcome("Suicide mortality") ///
    analysis("Mutually adjusted housing model") ///
    adjustment("Model 3: plus health care") vars($housing_pp)

esttab ///
    qseq_mh_all_m1 qseq_mh_all_m2 qseq_mh_all_m3 ///
    qseq_sui_all_m1 qseq_sui_all_m2 qseq_sui_all_m3 ///
    using "$output/TableS0F2_Sequential_combined_housing.rtf", replace ///
    keep($housing_pp) ///
    mtitles("MH M1" "MH M2" "MH M3" "Suicide M1" "Suicide M2" "Suicide M3") ///
    b(3) ci(3) label star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared")) ///
    title("Sequential adjustment in mutually adjusted housing models")

postclose `seqpost'

preserve
    use `seqdata', clear
    sort outcome analysis_name variable_name adjustment_level
    format beta standard_error ci_lower ci_upper %12.4f
    format p_value %9.4f
    format r_squared %9.3f
    save "$processed/sequential_adjustment_summary.dta", replace
    export excel using "$output/TableS0F_Sequential_adjustment_summary.xlsx", ///
        firstrow(variables) replace
    export delimited using "$output/TableS0F_Sequential_adjustment_summary.csv", replace
restore

********************************************************************************
* II-6. COMMON-SAMPLE PATHWAY-PROXY OUTCOME MODELS
********************************************************************************

/*
For each pathway proxy, the base and proxy-adjusted model use exactly the same
observations. This allows coefficient changes to be attributed to adjustment for
the proxy rather than to a changing sample.
*/

di "================ COMMON-SAMPLE PATHWAY-PROXY MODELS ================"
capture drop qa_mh_food qa_mh_sleep qa_mh_social qa_mh_allpath
capture drop qa_sui_food qa_sui_sleep qa_sui_social qa_sui_allpath

gen byte qa_mh_food = qa_sample_mh & !missing(food_insecurity_pp)
gen byte qa_mh_sleep = qa_sample_mh & !missing(insufficient_sleep_pp)
gen byte qa_mh_social = qa_sample_mh & !missing(loneliness_pp, lack_social_support_pp)
gen byte qa_mh_allpath = qa_sample_mh & ///
    !missing(food_insecurity_pp, insufficient_sleep_pp, loneliness_pp, lack_social_support_pp)

gen byte qa_sui_food = qa_sample_sui & !missing(food_insecurity_pp)
gen byte qa_sui_sleep = qa_sample_sui & !missing(insufficient_sleep_pp)
gen byte qa_sui_social = qa_sample_sui & !missing(loneliness_pp, lack_social_support_pp)
gen byte qa_sui_allpath = qa_sample_sui & ///
    !missing(food_insecurity_pp, insufficient_sleep_pp, loneliness_pp, lack_social_support_pp)

foreach s in qa_mh_food qa_mh_sleep qa_mh_social qa_mh_allpath ///
             qa_sui_food qa_sui_sleep qa_sui_social qa_sui_allpath {
    quietly count if `s' == 1
    di as result "`s': " r(N)
    tab year if `s' == 1
}

tempname pathpost
tempfile pathdata
postfile `pathpost' str35 outcome str45 analysis str45 adjustment ///
    str40 variable_name str80 variable_label ///
    double beta standard_error ci_lower ci_upper p_value ///
    long observations double r_squared using `pathdata', replace

eststo clear

* ---------------- Poor mental health days: food insecurity ----------------
reg mental_health $housing_pp $controls_pp i.year if qa_mh_food == 1, vce(cluster fipscode)
eststo qpath_mh_food_base
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("Food insecurity sample") adjustment("Base model on same sample") ///
    vars($housing_pp)

reg mental_health $housing_pp food_insecurity_pp $controls_pp i.year ///
    if qa_mh_food == 1, vce(cluster fipscode)
eststo qpath_mh_food_adj
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("Food insecurity sample") adjustment("Plus food insecurity") ///
    vars($housing_pp food_insecurity_pp)

esttab qpath_mh_food_base qpath_mh_food_adj ///
    using "$output/TableS0G1_MH_common_sample_food.rtf", replace ///
    keep($housing_pp food_insecurity_pp) mtitles("Base, same sample" "+ Food insecurity") ///
    b(3) ci(3) label star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared"))

* ---------------- Poor mental health days: insufficient sleep ----------------
reg mental_health $housing_pp $controls_pp i.year if qa_mh_sleep == 1, vce(cluster fipscode)
eststo qpath_mh_sleep_base
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("Insufficient sleep sample") adjustment("Base model on same sample") ///
    vars($housing_pp)

reg mental_health $housing_pp insufficient_sleep_pp $controls_pp i.year ///
    if qa_mh_sleep == 1, vce(cluster fipscode)
eststo qpath_mh_sleep_adj
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("Insufficient sleep sample") adjustment("Plus insufficient sleep") ///
    vars($housing_pp insufficient_sleep_pp)

esttab qpath_mh_sleep_base qpath_mh_sleep_adj ///
    using "$output/TableS0G2_MH_common_sample_sleep.rtf", replace ///
    keep($housing_pp insufficient_sleep_pp) mtitles("Base, same sample" "+ Insufficient sleep") ///
    b(3) ci(3) label star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared"))

* ---------------- Poor mental health days: social proxies ----------------
reg mental_health $housing_pp $controls_pp i.year if qa_mh_social == 1, vce(cluster fipscode)
eststo qpath_mh_social_base
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("Social proxy sample") adjustment("Base model on same sample") ///
    vars($housing_pp)

reg mental_health $housing_pp loneliness_pp $controls_pp i.year ///
    if qa_mh_social == 1, vce(cluster fipscode)
eststo qpath_mh_lonely
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("Social proxy sample") adjustment("Plus loneliness") ///
    vars($housing_pp loneliness_pp)

reg mental_health $housing_pp lack_social_support_pp $controls_pp i.year ///
    if qa_mh_social == 1, vce(cluster fipscode)
eststo qpath_mh_support
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("Social proxy sample") adjustment("Plus lack social support") ///
    vars($housing_pp lack_social_support_pp)

reg mental_health $housing_pp loneliness_pp lack_social_support_pp $controls_pp i.year ///
    if qa_mh_social == 1, vce(cluster fipscode)
eststo qpath_mh_social_both
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("Social proxy sample") adjustment("Plus both social proxies") ///
    vars($housing_pp loneliness_pp lack_social_support_pp)

esttab qpath_mh_social_base qpath_mh_lonely ///
    qpath_mh_support qpath_mh_social_both ///
    using "$output/TableS0G3_MH_common_sample_social.rtf", replace ///
    keep($housing_pp loneliness_pp lack_social_support_pp) ///
    mtitles("Base, same sample" "+ Loneliness" "+ Lack support" "+ Both") ///
    b(3) ci(3) label star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared"))

* ---------------- Poor mental health days: all proxies ----------------
reg mental_health $housing_pp $controls_pp i.year if qa_mh_allpath == 1, vce(cluster fipscode)
eststo qpath_mh_all_base
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("All pathway proxies sample") adjustment("Base model on same sample") ///
    vars($housing_pp)

reg mental_health $housing_pp food_insecurity_pp insufficient_sleep_pp ///
    loneliness_pp lack_social_support_pp $controls_pp i.year ///
    if qa_mh_allpath == 1, vce(cluster fipscode)
eststo qpath_mh_all_adj
qa_post_estimates, handle(`pathpost') outcome("Poor mental health days") ///
    analysis("All pathway proxies sample") adjustment("Plus all pathway proxies") ///
    vars($housing_pp food_insecurity_pp insufficient_sleep_pp loneliness_pp lack_social_support_pp)

esttab qpath_mh_all_base qpath_mh_all_adj ///
    using "$output/TableS0G4_MH_common_sample_all_proxies.rtf", replace ///
    keep($housing_pp food_insecurity_pp insufficient_sleep_pp loneliness_pp lack_social_support_pp) ///
    mtitles("Base, same sample" "+ All proxies") ///
    b(3) ci(3) label star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared"))

* ---------------- Suicide mortality: food and sleep proxies ----------------
reg suicide_rate $housing_pp $controls_pp i.year if qa_sui_food == 1, vce(cluster fipscode)
eststo qpath_sui_food_base
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("Food insecurity sample") adjustment("Base model on same sample") ///
    vars($housing_pp)

reg suicide_rate $housing_pp food_insecurity_pp $controls_pp i.year ///
    if qa_sui_food == 1, vce(cluster fipscode)
eststo qpath_sui_food_adj
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("Food insecurity sample") adjustment("Plus food insecurity") ///
    vars($housing_pp food_insecurity_pp)

reg suicide_rate $housing_pp $controls_pp i.year if qa_sui_sleep == 1, vce(cluster fipscode)
eststo qpath_sui_sleep_base
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("Insufficient sleep sample") adjustment("Base model on same sample") ///
    vars($housing_pp)

reg suicide_rate $housing_pp insufficient_sleep_pp $controls_pp i.year ///
    if qa_sui_sleep == 1, vce(cluster fipscode)
eststo qpath_sui_sleep_adj
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("Insufficient sleep sample") adjustment("Plus insufficient sleep") ///
    vars($housing_pp insufficient_sleep_pp)

esttab qpath_sui_food_base qpath_sui_food_adj ///
    qpath_sui_sleep_base qpath_sui_sleep_adj ///
    using "$output/TableS0G5_Suicide_common_sample_food_sleep.rtf", replace ///
    keep($housing_pp food_insecurity_pp insufficient_sleep_pp) ///
    mtitles("Food base" "+ Food" "Sleep base" "+ Sleep") ///
    b(3) ci(3) label star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared"))

* ---------------- Suicide mortality: social and all proxies ----------------
reg suicide_rate $housing_pp $controls_pp i.year if qa_sui_social == 1, vce(cluster fipscode)
eststo qpath_sui_social_base
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("Social proxy sample") adjustment("Base model on same sample") ///
    vars($housing_pp)

reg suicide_rate $housing_pp loneliness_pp $controls_pp i.year ///
    if qa_sui_social == 1, vce(cluster fipscode)
eststo qpath_sui_lonely
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("Social proxy sample") adjustment("Plus loneliness") ///
    vars($housing_pp loneliness_pp)

reg suicide_rate $housing_pp lack_social_support_pp $controls_pp i.year ///
    if qa_sui_social == 1, vce(cluster fipscode)
eststo qpath_sui_support
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("Social proxy sample") adjustment("Plus lack social support") ///
    vars($housing_pp lack_social_support_pp)

reg suicide_rate $housing_pp loneliness_pp lack_social_support_pp $controls_pp i.year ///
    if qa_sui_social == 1, vce(cluster fipscode)
eststo qpath_sui_social_both
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("Social proxy sample") adjustment("Plus both social proxies") ///
    vars($housing_pp loneliness_pp lack_social_support_pp)

esttab qpath_sui_social_base qpath_sui_lonely ///
    qpath_sui_support qpath_sui_social_both ///
    using "$output/TableS0G6_Suicide_common_sample_social.rtf", replace ///
    keep($housing_pp loneliness_pp lack_social_support_pp) ///
    mtitles("Base, same sample" "+ Loneliness" "+ Lack support" "+ Both") ///
    b(3) ci(3) label star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared"))

reg suicide_rate $housing_pp $controls_pp i.year if qa_sui_allpath == 1, vce(cluster fipscode)
eststo qpath_sui_all_base
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("All pathway proxies sample") adjustment("Base model on same sample") ///
    vars($housing_pp)

reg suicide_rate $housing_pp food_insecurity_pp insufficient_sleep_pp ///
    loneliness_pp lack_social_support_pp $controls_pp i.year ///
    if qa_sui_allpath == 1, vce(cluster fipscode)
eststo qpath_sui_all_adj
qa_post_estimates, handle(`pathpost') outcome("Suicide mortality") ///
    analysis("All pathway proxies sample") adjustment("Plus all pathway proxies") ///
    vars($housing_pp food_insecurity_pp insufficient_sleep_pp loneliness_pp lack_social_support_pp)

esttab qpath_sui_all_base qpath_sui_all_adj ///
    using "$output/TableS0G7_Suicide_common_sample_all_proxies.rtf", replace ///
    keep($housing_pp food_insecurity_pp insufficient_sleep_pp loneliness_pp lack_social_support_pp) ///
    mtitles("Base, same sample" "+ All proxies") ///
    b(3) ci(3) label star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared"))

postclose `pathpost'

preserve
    use `pathdata', clear
    rename analysis pathway_sample
    rename adjustment model_specification
    sort outcome pathway_sample model_specification variable_name
    format beta standard_error ci_lower ci_upper %12.4f
    format p_value %9.4f
    format r_squared %9.3f
    save "$processed/common_sample_pathway_summary.dta", replace
    export excel using "$output/TableS0G_Common_sample_pathway_summary.xlsx", ///
        firstrow(variables) replace
    export delimited using "$output/TableS0G_Common_sample_pathway_summary.csv", replace
restore

********************************************************************************
* II-7. HOUSING CORRELATION MATRICES
********************************************************************************

di "================ HOUSING CORRELATIONS ================"
quietly correlate $housing_pp if qa_sample_mh == 1
matrix C_mh = r(C)

putexcel set "$output/TableS0H_Housing_correlation_matrices.xlsx", ///
    sheet("MH_sample") replace
putexcel A1 = "Housing correlation matrix: poor mental health analytic sample"
putexcel A3 = matrix(C_mh), names

quietly correlate $housing_pp if qa_sample_sui == 1
matrix C_sui = r(C)

putexcel set "$output/TableS0H_Housing_correlation_matrices.xlsx", ///
    sheet("Suicide_sample") modify
putexcel A1 = "Housing correlation matrix: suicide analytic sample"
putexcel A3 = matrix(C_sui), names

* Display pairwise correlations with P values in the log as an additional check.
pwcorr $housing_pp if qa_sample_mh == 1, sig obs
pwcorr $housing_pp if qa_sample_sui == 1, sig obs

********************************************************************************
* II-8. MANUAL VIF DIAGNOSTICS FOR FULL PREDICTOR SET
********************************************************************************

/*
VIF is computed for each continuous predictor by regressing it on all other
continuous predictors plus release-year indicators. VIF does not depend on the
outcome or on clustered standard errors, but it can differ across analytic samples.
*/

di "================ VIF DIAGNOSTICS ================"
local vif_predictors ///
    $housing_pp $demographic_covars_pp ///
    median_income unemployment_pp child_poverty_pp pct_rural_pp ///
    hs_completion_pp some_college_pp ///
    $healthcare_covars

tempname vifpost
tempfile vifdata
postfile `vifpost' str30 analytic_sample str40 variable_name str80 variable_label ///
    double vif tolerance auxiliary_r_squared long observations ///
    using `vifdata', replace

foreach sample_name in MH Suicide {
    if "`sample_name'" == "MH" local sample_if "qa_sample_mh == 1"
    if "`sample_name'" == "Suicide" local sample_if "qa_sample_sui == 1"

    foreach x of local vif_predictors {
        local others : list vif_predictors - x
        quietly regress `x' `others' i.year if `sample_if'
        local aux_r2 = e(r2)
        local this_n = e(N)
        local this_vif = .
        local this_tol = .
        if (`aux_r2' < 1) {
            local this_vif = 1 / (1 - `aux_r2')
            local this_tol = 1 / `this_vif'
        }
        local vlabel : variable label `x'
        if `"`vlabel'"' == "" local vlabel "`x'"

        post `vifpost' ("`sample_name'") ("`x'") (`"`vlabel'"') ///
            (`this_vif') (`this_tol') (`aux_r2') (`this_n')
    }
}
postclose `vifpost'

preserve
    use `vifdata', clear
    gsort analytic_sample -vif
    format vif tolerance auxiliary_r_squared %9.3f
    save "$processed/vif_diagnostics.dta", replace
    export excel using "$output/TableS0I_VIF_diagnostics.xlsx", ///
        firstrow(variables) replace
    export delimited using "$output/TableS0I_VIF_diagnostics.csv", replace

    bysort analytic_sample: summarize vif, detail
restore

********************************************************************************
* II-9. COMPLETION SUMMARY AND FREEZE MANIFEST
********************************************************************************

di "=================================================================="
di as result "Reviewer-driven QA analyses completed."
di as result "Freeze-candidate analysis data were reloaded and were not overwritten in Phase II."
di as result "Review outputs in: $output"
di "=================================================================="

********************************************************************************
* II-10. FINAL CODE-FREEZE CHECKS AND MANIFEST
********************************************************************************

quietly count
local final_check_total = r(N)
assert `final_check_total' == $EXPECTED_TOTAL
quietly count if qa_sample_mh == 1
local final_check_mh = r(N)
assert `final_check_mh' == $EXPECTED_MH_FINAL
quietly count if qa_sample_sui == 1
local final_check_sui = r(N)
assert `final_check_sui' == $EXPECTED_SUI_FINAL

assert scalar(freeze_n_mh) == $EXPECTED_MH_FINAL
assert scalar(freeze_n_sui) == $EXPECTED_SUI_FINAL

file open freeze_manifest using "$output/ANALYSIS_FREEZE_MANIFEST.txt", write text replace
file write freeze_manifest "RWJF County Housing and Mental Health Analysis" _n
file write freeze_manifest "Freeze candidate version: $freeze_tag" _n
file write freeze_manifest "Generated by merged main + reviewer-QA do-file" _n _n
file write freeze_manifest "ELIGIBLE COUNTY-RELEASE RECORDS" _n
file write freeze_manifest "Total after geography restriction: " %10.0f ($EXPECTED_TOTAL) _n
file write freeze_manifest "Poor mental health outcome observed: " %10.0f ($EXPECTED_MH_OBSERVED) _n
file write freeze_manifest "Poor mental health final sample: " %10.0f ($EXPECTED_MH_FINAL) _n
file write freeze_manifest "Suicide mortality outcome observed: " %10.0f ($EXPECTED_SUI_OBSERVED) _n
file write freeze_manifest "Suicide mortality final sample: " %10.0f ($EXPECTED_SUI_FINAL) _n _n
file write freeze_manifest "MUTUALLY ADJUSTED KEY COEFFICIENTS (per 1 percentage point)" _n
file write freeze_manifest "MH: severe housing cost burden = " %9.6f (scalar(freeze_b_mh_cost)) _n
file write freeze_manifest "MH: long commuting = " %9.6f (scalar(freeze_b_mh_long)) _n
file write freeze_manifest "MH: homeownership = " %9.6f (scalar(freeze_b_mh_own)) _n
file write freeze_manifest "Suicide: overcrowding = " %9.6f (scalar(freeze_b_sui_crowd)) _n
file write freeze_manifest "Suicide: lack kitchen/plumbing facilities = " %9.6f (scalar(freeze_b_sui_lack)) _n _n
file write freeze_manifest "STATUS: CODE FREEZE CHECKS PASSED" _n
file close freeze_manifest

di "=================================================================="
di as result "CODE FREEZE CHECKS PASSED"
di as result "Freeze manifest: $output/ANALYSIS_FREEZE_MANIFEST.txt"
di as result "Main log: $output/01_main_analysis.log"
di as result "QA log: $output/02_reviewer_QA.log"
di "=================================================================="

log close
