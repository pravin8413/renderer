import hashlib
import io
import json
import os
import re
import tempfile
from pathlib import Path

import ibm_boto3
from ibm_botocore.client import Config


def main(args):

    cos = createCOSClient(args)

    if not cos:
        raise ValueError("could not create COS instance")

    notification = args.get('notification', {})
    trigger_key = notification.get('object_name', '')

    src_bucket = args.get('src_bucket')
    dst_bucket = args.get('dst_bucket')

    mo = re.match(r'^(.*?)\+(.*?)\+(.*?)\.(.*?)$', trigger_key)
    if not mo:
        raise ValueError(f"Could not parse key: {rendition_key}")

    choir_id, song_id, part_id, ext = mo.groups()

    prefix_key = f"{choir_id}+{song_id}"

    contents = cos.list_objects(
        Bucket=src_bucket,
        Prefix=prefix_key
    )

    files = [ x['Key'] for x in contents['Contents'] ]
    # stable random sort in order to create more pleasing output
    files.sort(key=lambda x: hashlib.sha1(x.encode('utf-8')).hexdigest())

    if len(files) >= 3:
        args['COS_SRC_BUCKET'] = src_bucket
        args['COS_DST_BUCKET'] = dst_bucket
        args['videos'] = files
        args['width'] = 1080
        args['height'] = 720
        args['margin'] = 10
        args['center'] = True
        args['pan'] = True
        args['reverbType'] = 'hall'
        args['reverbMix'] = 0.1
        args['outputKey'] = f'{prefix_key}+final.mp4'

        return args

    raise ValueError(f"Not enough videos to pass to sticher, only found {len(files)} videos")


def createCOSClient(args):
    """
    Create a ibm_boto3.client using the connectivity information
    contained in args.

    :param args: action parameters
    :type args: dict
    :return: An ibm_boto3.client
    :rtype: ibm_boto3.client
    """

    # if a Cloud Object Storage endpoint parameter was specified
    # make sure the URL contains the https:// scheme or the COS
    # client cannot connect
    if args.get('endpoint') and not args['endpoint'].startswith('https://'):
        args['endpoint'] = 'https://{}'.format(args['endpoint'])

    # set the Cloud Object Storage endpoint
    endpoint = args.get('endpoint',
                        'https://s3.us.cloud-object-storage.appdomain.cloud')

    # extract Cloud Object Storage service credentials
    cos_creds = args.get('__bx_creds', {}).get('cloud-object-storage', {})

    # set Cloud Object Storage API key
    api_key_id = \
        args.get('apikey',
                 args.get('apiKeyId',
                          cos_creds.get('apikey',
                                        os.environ
                                        .get('__OW_IAM_NAMESPACE_API_KEY')
                                        or '')))

    if not api_key_id:
        # fatal error; it appears that no Cloud Object Storage instance
        # was bound to the action's package
        return None

    # set Cloud Object Storage instance id
    svc_instance_id = args.get('resource_instance_id',
                               args.get('serviceInstanceId',
                                        cos_creds.get('resource_instance_id',
                                                      '')))
    if not svc_instance_id:
        # fatal error; it appears that no Cloud Object Storage instance
        # was bound to the action's package
        return None

    ibm_auth_endpoint = args.get('ibmAuthEndpoint',
                                 'https://iam.cloud.ibm.com/identity/token')

    # Create a Cloud Object Storage client using the provided
    # connectivity information
    cos = ibm_boto3.client('s3',
                           ibm_api_key_id=api_key_id,
                           ibm_service_instance_id=svc_instance_id,
                           ibm_auth_endpoint=ibm_auth_endpoint,
                           config=Config(signature_version='oauth'),
                           endpoint_url=endpoint)

    # Return Cloud Object Storage client
    return cos
