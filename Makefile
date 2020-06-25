# Cloud Object Storage instance name 
COS_INSTANCE_NAME ?= cloud-object-storage-cb

# Regional buckets in above Cloud Object Storage instance
RAW_BUCKET_NAME ?= choirless-videos-raw
CONVERTED_BUCKET_NAME ?= choirless-videos-converted
TRIMMED_BUCKET_NAME ?= choirless-videos-trimmed

# Namespace functions will be created int
NAMESPACE_NAME ?= choirless

all: clean build

build: namespace cos-auth package actions sequences triggers rules list

clean:
	for namespace in `ibmcloud fn namespace list | egrep  "^choirless " | awk '{print $$3}'`; do \
		ic fn trigger list /$${namespace} | grep "/" | awk '{print $$1}' | xargs -n1 ic fn trigger delete ; \
		ic fn action list /$${namespace} | grep "/" | awk '{print $$1}' | xargs -n1 ic fn action delete ; \
		ic fn rule list /$${namespace} | grep "/" | awk '{print $$1}' | xargs -n1 ic fn rule delete ; \
		ic fn package list /$${namespace} | grep "/" | awk '{print $$1}' | xargs -n1 ic fn package delete ; \
		ic fn namespace delete $${namespace} ; \
	done

# Create and set namespace
namespace:
	ibmcloud fn namespace create $(NAMESPACE_NAME) --description "Choirless video processing service"
	ibmcloud fn property set --namespace $(NAMESPACE_NAME)

# Prepare namespace for Cloud Object Storage triggers
cos-auth:
	ibmcloud iam authorization-policy-create functions cloud-object-storage "Notifications Manager" --source-service-instance-name $(NAMESPACE_NAME) --target-service-instance-name $(COS_INSTANCE_NAME)

# Create the package
package:
	ibmcloud fn package create choirless
	# Bind COS instance to the package
	ibmcloud fn service bind cloud-object-storage choirless --instance $(COS_INSTANCE_NAME)

# Actions
actions:
	# Convert format
	ibmcloud fn action update choirless/convert_format aligner/convert_format.py --param src_bucket $(RAW_BUCKET_NAME) --param dst_bucket $(CONVERTED_BUCKET_NAME) \
	 --docker hammertoe/librosa_ml:latest --timeout 600000 --memory 512

	# Calculate alignment
	ibmcloud fn action update choirless/calculate_alignment aligner/calculate_alignment.py --param bucket $(CONVERTED_BUCKET_NAME) \
	 --docker hammertoe/librosa_ml:latest --timeout 600000 --memory 512

	# Trim clip
	ibmcloud fn action update choirless/trim_clip aligner/trim_clip.py --param src_bucket $(CONVERTED_BUCKET_NAME) --param dst_bucket $(TRIMMED_BUCKET_NAME)  \
	 --docker hammertoe/librosa_ml:latest --timeout 600000 --memory 512

	# Pass to sticher
	ibmcloud fn action update choirless/pass_to_sticher aligner/pass_to_sticher.py --param bucket $(TRIMMED_BUCKET_NAME) \
	 --docker hammertoe/librosa_ml:latest --timeout 600000 --memory 512

	# Sticher
	ibmcloud fn action update choirless/stitcher stitcher/index.js \
         --docker glynnbird/choirless_stitcher:1.0.0 --memory 2048 -t 600000

	# Renderer
	ibmcloud fn action update choirless/renderer renderer/index.js \
	--docker glynnbird/choirless_renderer:1.0.3 --memory 2048 -t 600000

sequences:
	# Calc alignment and Trim amd stitch
	ibmcloud fn action update choirless/calc_and_trim --sequence choirless/calculate_alignment,choirless/trim_clip
	ibmcloud fn action update choirless/stitch --sequence choirless/pass_to_sticher,choirless/stitcher

triggers:
	# Upload to raw bucket
	ibmcloud fn trigger create bucket_raw_upload_trigger --feed /whisk.system/cos/changes --param bucket $(RAW_BUCKET_NAME) --param event_types write

	# Upload to converted bucket
	ibmcloud fn trigger create bucket_converted_upload_trigger --feed /whisk.system/cos/changes --param bucket $(CONVERTED_BUCKET_NAME) --param event_types write

	# Upload to trummed bucket
	ibmcloud fn trigger create bucket_trimmed_upload_trigger --feed /whisk.system/cos/changes --param bucket $(TRIMMED_BUCKET_NAME) --param event_types write

rules:
	# Upload to raw bucket
	ibmcloud fn rule create bucket_raw_upload_rule bucket_raw_upload_trigger choirless/convert_format

	# Upload to converted bucket
	ibmcloud fn rule create bucket_converted_upload_rule bucket_converted_upload_trigger choirless/calc_and_trim

	# Upload to trimmed bucket
	ibmcloud fn rule create bucket_trimmed_upload_rule bucket_trimmed_upload_trigger choirless/stitch

list:
	# Display entities in the current namespace
	ibmcloud fn list

