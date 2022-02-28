/*
========================================================================================
    VALIDATE INPUTS
========================================================================================
*/

def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)

// Validate input parameters
WorkflowRnafusion.initialise(params, log)

// TODO nf-core: Add all file path parameters for the pipeline to the list below
// Check input path parameters to see if they exist


def checkPathParamList = [
    params.input, params.multiqc_config,
    params.fasta, params.genomes_base,
    params.ensembl_ref,
    params.fusioncatcher_ref, params.starfusion_ref,
    params.arriba_ref, params.ericscript_ref,
    params.ensembl_version
]


// Check mandatory parameters
if (params.input) { ch_input = file(params.input) } else { exit 1, 'Input samplesheet not specified!' }


/*
========================================================================================
    CONFIG FILES
========================================================================================
*/

ch_multiqc_config        = file("$projectDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config) : Channel.empty()

/*
========================================================================================
    IMPORT LOCAL MODULES/SUBWORKFLOWS
========================================================================================
*/

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { INPUT_CHECK                   }   from '../subworkflows/local/input_check'
include { ERICSCRIPT                    }   from '../modules/local/ericscript/detect/main'
include { FUSIONCATCHER                 }   from '../modules/local/fusioncatcher/detect/main'

include { ARRIBA_WORKFLOW               }   from '../subworkflows/local/arriba_workflow'
include { PIZZLY_WORKFLOW               }   from '../subworkflows/local/pizzly_workflow'
include { SQUID_WORKFLOW                }   from '../subworkflows/local/squid_workflow'
include { STARFUSION_WORKFLOW           }   from '../subworkflows/local/starfusion_workflow'
include { FUSIONREPORT_WORKFLOW         }   from '../subworkflows/local/fusionreport_workflow'

/*
========================================================================================
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
========================================================================================
*/

//
// MODULE: Installed directly from nf-core/modules
//
include { FASTQC                      } from '../modules/nf-core/modules/fastqc/main'
include { MULTIQC                     } from '../modules/nf-core/modules/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/modules/custom/dumpsoftwareversions/main'




/*
========================================================================================
    RUN MAIN WORKFLOW
========================================================================================
*/

// Info required for completion email and summary
def multiqc_report = []

workflow RNAFUSION {

    ch_versions = Channel.empty()

    //
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    //
    INPUT_CHECK (
        ch_input
    )
    ch_versions = ch_versions.mix(INPUT_CHECK.out.versions)


    //
    // MODULE: Run FastQC
    //
    FASTQC (
        INPUT_CHECK.out.reads
    )
    ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowRnafusion.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(Channel.from(ch_multiqc_config))
    ch_multiqc_files = ch_multiqc_files.mix(ch_multiqc_custom_config.collect().ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]}.ifEmpty([]))

    MULTIQC (
        ch_multiqc_files.collect()
    )

    multiqc_report       = MULTIQC.out.report.toList()
    ch_versions          = ch_versions.mix(MULTIQC.out.versions)

    // Run STAR alignment and Arriba
    ARRIBA_WORKFLOW (
        INPUT_CHECK.out.reads,
        params.fasta,
        params.starindex_ref,
    )

    // Run pizzly/kallisto

    PIZZLY_WORKFLOW (
        INPUT_CHECK.out.reads,
    )


// Run squid
    SQUID_WORKFLOW (
        INPUT_CHECK.out.reads,
        params.fasta
    )


//Run STAR fusion

    STARFUSION_WORKFLOW (
        INPUT_CHECK.out.reads
    )

    //Run FusionCatcher
    // if (params.fusioncatcher){
    //     FUSIONCATCHER (
    //         INPUT_CHECK.out.reads,
    //         params.fusioncatcher_ref
    //     )
    // }



     //Run fusion-report
    FUSIONREPORT_WORKFLOW (
        INPUT_CHECK.out.reads,
        params.fusionreport_ref,
        ARRIBA_WORKFLOW.out.fusions,
        PIZZLY_WORKFLOW.out.fusions,
        SQUID_WORKFLOW.out.fusions,
        STARFUSION_WORKFLOW.out.fusions
    )
}




/*
========================================================================================
    COMPLETION EMAIL AND SUMMARY
========================================================================================
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
}

/*
========================================================================================
    THE END
========================================================================================
*/
